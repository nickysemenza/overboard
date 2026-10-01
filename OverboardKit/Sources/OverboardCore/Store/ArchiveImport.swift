import Foundation
import GRDB

struct ArchiveEmbeddingCandidate: Codable {
    let id: String
    let text: String
}

private struct ArchiveItemOutcome {
    let inserted: Bool
    let repaired: Int
    let id: String
    let embeddingText: String?
}

private struct ArchiveRestoredItem {
    var item: ClipItem
    let sensitiveLabel: String?
}

struct ArchiveImport: Sendable {
    let prepared: PreparedArchive
    let blobs: BlobStore
    let limits: ClipArchive.Limits

    func merge(in database: Database, embeddingOutput: FileHandle) throws -> ImportSummary {
        var result = ImportSummary(
            imported: 0, duplicatesSkipped: 0, malformedLines: self.prepared.malformed,
            missingBlobs: self.prepared.missingBlobs, settings: self.prepared.settings
        )
        try self.mergeItems(in: database, embeddingOutput: embeddingOutput, result: &result)
        try self.mergeSnippets(in: database, result: &result)
        try Task.checkCancellation()
        return result
    }

    private func mergeItems(in database: Database, embeddingOutput: FileHandle,
                            result: inout ImportSummary) throws
    {
        let decoder = ClipJSONCoding.archiveDecoder()
        _ = try ArchiveIO
            .lines(ClipArchive.itemsFileName, in: self.prepared.directory, limits: self.limits) { line, _ in
                let record = try decoder.decode(ClipArchive.Record.self, from: line)
                let outcome = try self.mergeItem(record, in: database)
                result.imported += outcome.inserted ? 1 : 0
                result.duplicatesSkipped += outcome.inserted ? 0 : 1
                result.representationsRepaired += outcome.repaired
                if outcome.inserted, let text = outcome.embeddingText {
                    let candidate = ArchiveEmbeddingCandidate(id: outcome.id, text: text)
                    let data = try ClipJSONCoding.archiveEncoder().encode(candidate)
                    try embeddingOutput.write(contentsOf: data + Data([0x0A]))
                }
            }
    }

    private func mergeSnippets(in database: Database, result: inout ImportSummary) throws {
        let decoder = ClipJSONCoding.archiveDecoder()
        _ = try ArchiveIO
            .lines(ClipArchive.snippetsFileName, in: self.prepared.directory, limits: self.limits) { line, _ in
                let snippet = try decoder.decode(Snippet.self, from: line)
                if try self.mergeSnippet(snippet, in: database) {
                    result.snippetsImported += 1
                }
            }
    }

    private func mergeSnippet(_ original: Snippet, in database: Database) throws -> Bool {
        var snippet = original
        if let existing = try Snippet.fetchOne(database, key: snippet.id) {
            if Self.matches(existing, snippet) {
                return false
            }
            let identity = try ClipJSONCoding.archiveEncoder().encode(snippet)
            snippet.id = "archive-" + BlobStore.hash(identity)
            if let recovered = try Snippet.fetchOne(database, key: snippet.id) {
                guard Self.matches(recovered, snippet) else {
                    throw ClipArchive.Failure.invalid("conflicting recovered snippet")
                }
                return false
            }
        }
        try snippet.insert(database)
        return true
    }

    private static func matches(_ existing: Snippet, _ imported: Snippet) -> Bool {
        existing.title == imported.title && existing.body == imported.body && existing.deletedAt == nil
    }

    private func mergeItem(_ record: ClipArchive.Record, in database: Database) throws -> ArchiveItemOutcome {
        let existing = try ClipItem
            .filter(sql: "contentHash = ? AND deletedAt IS NULL", arguments: [record.contentHash]).fetchOne(database)
        let taken = try ClipItem.filter(key: record.id).fetchCount(database) > 0
        let id = existing?.id ?? (taken ? UUID().uuidString : record.id)
        let restored = try self.restore(record, id: id)
        try self.persist(restored, existing: existing, record: record, in: database)
        let repaired = try self.mergeRepresentations(record, itemID: id, isExisting: existing != nil, in: database)
        return ArchiveItemOutcome(
            inserted: existing == nil, repaired: repaired, id: id,
            embeddingText: restored.item.isSecret ? nil : record.searchText.map { String($0.prefix(300)) }
        )
    }

    private func restore(_ record: ClipArchive.Record, id: String) throws -> ArchiveRestoredItem {
        guard var item = record.clipItem(id: id) else { throw ClipArchive.Failure.invalid("item kind") }
        let sensitiveLabel = try ArchiveSensitivity.label(
            for: record.representations, in: self.prepared.directory, sharded: false, limit: self.limits.blobBytes
        ) ?? record.searchText.flatMap { ClipSensitivity.label(for: $0) }
        if record.secret || sensitiveLabel != nil {
            item.isSecret = true
            item.previewText = ClipSensitivity.maskedPreview(label: sensitiveLabel ?? "Secret")
            item.sourceURL = nil
            item.sourceTitle = nil
            item.aiTitle = nil
            item.aiSummary = nil
            item.category = nil
            item.linkTitle = nil
            item.linkDescription = nil
            item.faviconData = nil
            item.previewImageData = nil
            item.charCount = nil
            item.lineCount = nil
            item.pixelWidth = nil
            item.pixelHeight = nil
            item.fileCount = nil
        }
        return ArchiveRestoredItem(item: item, sensitiveLabel: sensitiveLabel)
    }

    private func persist(_ restored: ArchiveRestoredItem, existing: ClipItem?, record: ClipArchive.Record,
                         in database: Database) throws
    {
        if var existing {
            existing.isPinned = existing.isPinned || record.pinned
            try existing.update(database)
            if restored.item.isSecret {
                try ClipStore.protectSensitiveItem(
                    database, itemID: restored.item.id, label: restored.sensitiveLabel ?? "Secret"
                )
            }
        } else {
            try ClipStore.insertIndexed(
                database, item: restored.item, searchText: restored.item.isSecret ? nil : record.searchText
            )
        }
    }

    private func mergeRepresentations(_ record: ClipArchive.Record, itemID: String, isExisting: Bool,
                                      in database: Database) throws -> Int
    {
        var repaired = 0
        var existing = try Representation.filter(sql: "itemID = ?", arguments: [itemID]).fetchAll(database)
        for rep in record.representations {
            let payloadHash = rep.blob ?? rep.data.map(BlobStore.hash)
            guard let payloadHash else { throw ClipArchive.Failure.invalid("representation payload") }
            let repairedBlob = try self.repairBlob(for: rep)
            let matches = existing.contains { current in
                current.uti == rep.uti && current.itemIndex == rep.itemIndex
                    && (current.blobHash ?? current.data.map(BlobStore.hash)) == payloadHash
            }
            if !matches {
                let imported = Representation(
                    itemID: itemID, uti: rep.uti, data: rep.data, blobHash: rep.blob,
                    byteSize: rep.byteSize, itemIndex: rep.itemIndex
                )
                try imported.insert(database)
                existing.append(imported)
                if isExisting {
                    repaired += 1
                }
            } else if isExisting, repairedBlob {
                repaired += 1
            }
        }
        return repaired
    }

    private func repairBlob(for rep: ClipArchive.Rep) throws -> Bool {
        guard let hash = rep.blob,
              let available = try ArchiveIO.file("blobs/\(hash)", in: self.prepared.directory, optional: true)
        else { return false }
        try available.close()
        let wasMissing = try !ArchiveIO.validBlob(hash, size: rep.byteSize, in: self.blobs.directory)
        if wasMissing {
            try ArchiveIO.installBlob(hash, from: self.prepared.directory, in: self.blobs.directory)
        }
        return wasMissing
    }
}
