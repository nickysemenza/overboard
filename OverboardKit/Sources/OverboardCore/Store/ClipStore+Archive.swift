import Foundation

// MARK: - Import plumbing

/// One representation's bytes, resolved from the archive (inline or blob file)
/// and ready to be stored again.
struct ArchivePayload {
    let uti: String
    let bytes: Data
}

enum ImportOutcome {
    case inserted(String)
    case duplicate
    /// The record named a kind this build doesn't know — a newer archive.
    case malformed
}

private extension ClipStore {
    /// Resolves every representation of `record` to bytes, reading blob-backed
    /// ones out of the archive's `blobs/` folder. A representation whose file is
    /// missing is dropped (and counted) rather than failing the whole import:
    /// a text clip missing its RTF flavor still pastes.
    func archivePayloads(
        for record: ClipArchive.Record, blobsDirectory: URL, missingBlobs: inout Int
    ) -> [ArchivePayload] {
        var payloads: [ArchivePayload] = []
        for rep in record.representations {
            if let data = rep.data {
                payloads.append(ArchivePayload(uti: rep.uti, bytes: data))
            } else if let hash = rep.blob {
                guard let data = try? Data(contentsOf: blobsDirectory.appendingPathComponent(hash)) else {
                    missingBlobs += 1
                    continue
                }
                payloads.append(ArchivePayload(uti: rep.uti, bytes: data))
            }
        }
        return payloads
    }
}

// MARK: - Export / import

public extension ClipStore {
    /// Writes every live item to `directory` as `items.ndjson` plus a `blobs/`
    /// folder. Secrets are excluded by default: they are TTL-limited on purpose
    /// (see `CaptureClassifier`), and an archive that outlives the sweep would
    /// quietly defeat that.
    @discardableResult
    func export(to directory: URL, includeSecrets: Bool = false) async throws -> ExportSummary {
        let fileManager = FileManager.default
        let blobsDirectory = directory.appendingPathComponent(ClipArchive.blobsDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)

        let itemsURL = directory.appendingPathComponent(ClipArchive.itemsFileName)
        fileManager.createFile(atPath: itemsURL.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: itemsURL.path) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSURLErrorKey: itemsURL])
        }
        defer { try? handle.close() }

        let secretClause = includeSecrets ? "" : " AND isSecret = 0"
        let ids = try await self.exportableIDs(secretClause: secretClause)
        let secretsExcluded = includeSecrets ? 0 : try await self.liveSecretCount()

        let encoder = ClipJSONCoding.archiveEncoder()
        var written = 0
        var copiedHashes: Set<String> = []
        var blobsMissing = 0
        // Paged rather than one big fetch: inline representation payloads run to
        // 32 KB each, so a full history would otherwise land in memory at once.
        for chunk in stride(from: 0, to: ids.count, by: 200).map({
            Array(ids[$0 ..< Swift.min($0 + 200, ids.count)])
        }) {
            let records = try await self.exportRecords(ids: chunk)
            for record in records {
                var line = try encoder.encode(record)
                line.append(0x0A)
                try handle.write(contentsOf: line)
                written += 1
                blobsMissing += self.copyBlobs(
                    for: record,
                    into: blobsDirectory,
                    using: fileManager,
                    copiedHashes: &copiedHashes
                )
            }
        }

        return ExportSummary(
            directory: directory,
            itemCount: written,
            blobCount: copiedHashes.count,
            secretsExcluded: secretsExcluded,
            blobsMissing: blobsMissing
        )
    }

    /// Copies every blob a single record references into `blobsDirectory`,
    /// skipping hashes already copied this run. Returns the number that
    /// couldn't be copied (missing source or copy failure), which the caller
    /// accumulates into `ExportSummary.blobsMissing`. Split out of `export`
    /// to keep that function's body within the length limit.
    private func copyBlobs(
        for record: ClipArchive.Record,
        into blobsDirectory: URL,
        using fileManager: FileManager,
        copiedHashes: inout Set<String>
    ) -> Int {
        var missing = 0
        for hash in record.representations.compactMap(\.blob) where !copiedHashes.contains(hash) {
            guard let source = self.blobFileURL(for: hash) else {
                missing += 1
                continue
            }
            let destination = blobsDirectory.appendingPathComponent(hash)
            // Content-addressed, so an existing file is already identical.
            // The copy itself is outside the writer (export is paged and
            // the actor suspends between pages), so a purge can unlink
            // the source after `blobFileURL` saw it — count that rather
            // than abort a half-written archive.
            if !fileManager.fileExists(atPath: destination.path) {
                do {
                    try fileManager.copyItem(at: source, to: destination)
                } catch {
                    missing += 1
                    continue
                }
            }
            copiedHashes.insert(hash)
        }
        return missing
    }

    /// Reads an archive written by ``export(to:includeSecrets:)`` back into the
    /// store. Items whose `contentHash` already matches a live row are skipped;
    /// everything else is inserted through the same indexed-insert path capture
    /// uses, so imported clips are searchable immediately.
    func `import`(from directory: URL) async throws -> ImportSummary {
        let itemsURL = directory.appendingPathComponent(ClipArchive.itemsFileName)
        guard FileManager.default.fileExists(atPath: itemsURL.path) else {
            throw ClipArchive.Failure.notAnArchive(directory)
        }
        let blobsDirectory = directory.appendingPathComponent(ClipArchive.blobsDirectoryName, isDirectory: true)
        let decoder = ClipJSONCoding.archiveDecoder()
        let text = try String(contentsOf: itemsURL, encoding: .utf8)

        var malformed: [String] = []
        var records: [ClipArchive.Record] = []
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            do {
                try records.append(decoder.decode(ClipArchive.Record.self, from: Data(line.utf8)))
            } catch {
                // One bad line is one lost clip, not a failed restore.
                malformed.append("line \(offset + 1): \(error.localizedDescription)")
            }
        }

        var imported = 0
        var duplicates = 0
        var missingBlobs = 0
        var embeddable: [(id: String, text: String)] = []
        for record in records {
            let payloads = self.archivePayloads(
                for: record, blobsDirectory: blobsDirectory, missingBlobs: &missingBlobs
            )
            let outcome = try await self.insertImported(record: record, payloads: payloads)
            switch outcome {
            case .duplicate:
                duplicates += 1
            case let .inserted(id):
                imported += 1
                if !record.secret, record.kind == ItemKind.text.rawValue || record.kind == ItemKind.link.rawValue,
                   let searchText = record.searchText
                {
                    embeddable.append((id, searchText))
                }
            case .malformed:
                malformed.append("item \(record.id): unknown kind “\(record.kind)”")
            }
        }

        // Same best-effort semantic indexing `ingest` does: missing vectors only
        // cost the item its semantic hits, never the import.
        for candidate in embeddable {
            try? await self.storeEmbeddingIfPossible(itemID: candidate.id, text: candidate.text)
        }

        return ImportSummary(
            imported: imported,
            duplicatesSkipped: duplicates,
            malformedLines: malformed,
            missingBlobs: missingBlobs
        )
    }
}
