import Foundation
import GRDB

public extension ClipStore {
    @discardableResult
    func export(
        to directory: URL, includeSecrets: Bool = false,
        settings: ClipArchive.Settings? = nil, limits: ClipArchive.Limits = .init()
    ) async throws -> ExportSummary {
        try await self.exportArchive(
            to: directory, includeSecrets: includeSecrets, settings: settings,
            limits: limits, publish: ArchiveIO.publish
        )
    }

    func `import`(
        from directory: URL, limits: ClipArchive.Limits = .init(),
        validateSettings: @Sendable (ClipArchive.Settings?) throws -> Void = { _ in }
    ) async throws -> ImportSummary {
        try Task.checkCancellation()
        let prepared = try PreparedArchive(directory: directory, limits: limits)
        defer { prepared.remove() }
        try Task.checkCancellation()
        try validateSettings(prepared.settings)
        try Task.checkCancellation()
        let embeddingURL = prepared.directory.appendingPathComponent("embedding-candidates.ndjson")
        let embeddingOutput = try ArchiveIO.output(embeddingURL)
        defer { try? embeddingOutput.close() }
        let merger = ArchiveImport(prepared: prepared, blobs: self.blobs, limits: limits)
        let result = try await self.dbWriter.write { db in
            try merger.merge(in: db, embeddingOutput: embeddingOutput)
        }
        try? await self.restoreArchiveEmbeddings(from: prepared.directory)
        return result
    }
}

extension ClipStore {
    func exportArchive(
        to directory: URL, includeSecrets: Bool, settings: ClipArchive.Settings?,
        limits: ClipArchive.Limits,
        publish: @Sendable (URL, URL) throws -> Void
    ) async throws -> ExportSummary {
        try Task.checkCancellation()
        let staged = try ArchiveIO.temporaryDirectory(beside: directory)
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.createDirectory(
            at: staged.appendingPathComponent("blobs"),
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let blobs = self.blobs
        let snapshot = try await self.dbWriter.write { db in
            try ArchiveSnapshot.write(db: db, blobs: blobs, to: staged, includeSecrets: includeSecrets, limits: limits)
        }
        try Task.checkCancellation()
        var manifest = snapshot.manifest
        var settingsExcluded = 0
        if let settings {
            var settings = settings
            if !includeSecrets {
                let filtered = ArchiveSensitivity.filterSettings(settings)
                settingsExcluded = filtered.excluded
                settings = filtered.settings
            }
            let data = try ClipJSONCoding.archiveEncoder().encode(settings)
            guard data.count <= limits.lineBytes else { throw ClipArchive.Failure.limit("settings") }
            try ArchiveSnapshot.write(data, to: staged.appendingPathComponent(ClipArchive.settingsFileName))
            manifest.settingsChecksum = BlobStore.hash(data)
        }
        try ArchiveSnapshot.write(
            ClipJSONCoding.archiveEncoder().encode(manifest),
            to: staged.appendingPathComponent(ClipArchive.manifestFileName)
        )
        let verified = try PreparedArchive(directory: staged, limits: limits)
        verified.remove()
        try ArchiveIO.synchronizeDirectory(staged.appendingPathComponent("blobs"))
        try ArchiveIO.synchronizeDirectory(staged)
        try publish(staged, directory)
        return ExportSummary(
            directory: directory, itemCount: manifest.itemCount, blobCount: snapshot.copiedBlobs,
            secretsExcluded: snapshot.secretsExcluded + settingsExcluded, blobsMissing: snapshot.missingBlobs,
            snippetCount: manifest.snippetCount, includesSettings: settings != nil
        )
    }

    private func restoreArchiveEmbeddings(from directory: URL) async throws {
        guard let handle = try ArchiveIO.file("embedding-candidates.ndjson", in: directory) else { return }
        defer { try? handle.close() }
        var pending = Data()
        let decoder = ClipJSONCoding.archiveDecoder()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                if Task.isCancelled {
                    return
                }
                let line = Data(pending[..<newline])
                pending = Data(pending[pending.index(after: newline)...])
                let candidate = try decoder.decode(ArchiveEmbeddingCandidate.self, from: line)
                try? await self.storeEmbedding(itemID: candidate.id, text: candidate.text)
            }
        }
    }
}
