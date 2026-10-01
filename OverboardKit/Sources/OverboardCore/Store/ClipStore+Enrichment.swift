import Foundation
import GRDB

// MARK: - AI enrichment

public extension ClipStore {
    /// Attaches OCR'd text to an item that had none (images): becomes its
    /// searchText, enters the FTS index, and gets a semantic embedding —
    /// screenshots become findable by their contents.
    /// Empty text still sets the column (to "") so textless images are marked
    /// as attempted and don't get re-OCR'd by every backfill pass.
    @discardableResult
    func attachRecognizedText(itemID: String, text: String) async throws -> Bool {
        try Task.checkCancellation()
        let capped = String(text.prefix(CaptureClassifier.searchTextLimit))
        let sensitivity = ClipSensitivity.label(for: text)
        let attached: Bool = try await self.writeCancellable { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT rowid, searchText, isSecret FROM item WHERE id = ? AND deletedAt IS NULL",
                arguments: [itemID]
            ) else { return false }
            if let sensitivity {
                try Self.protectSensitiveItem(db, itemID: itemID, label: sensitivity)
                return false
            }
            guard !(row["isSecret"] as Bool) else { return false }
            guard (row["searchText"] as String?) == nil else { return true }
            try Self.checkItemCountersCanAdvance(db, itemID: itemID)

            try db.execute(
                sql: "UPDATE item SET searchText = ?, updatedAt = ?, lamport = lamport + 1 WHERE id = ?",
                arguments: [capped, Date(), itemID]
            )
            if !capped.isEmpty {
                try db.execute(
                    sql: "INSERT INTO item_fts (rowid, searchText) VALUES (?, ?)",
                    arguments: [row["rowid"] as Int64, capped]
                )
            }
            return true
        }
        try Task.checkCancellation()
        if attached, !capped.isEmpty {
            try? await self.storeEmbedding(itemID: itemID, text: capped)
        }
        return attached
    }

    /// Stores generated title + category + optional summary, and folds the
    /// AI text into the FTS index so items are findable by their generated
    /// descriptions, not just their literal content. Never overwrites an
    /// existing title.
    func attachEnrichment(
        itemID: String,
        title: String,
        category: String,
        summary: String? = nil
    ) async throws {
        try await self.writeCancellable { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT rowid, searchText FROM item
                WHERE id = ? AND aiTitle IS NULL AND isSecret = 0 AND deletedAt IS NULL
                """,
                arguments: [itemID]
            ) else { return }
            let rowid: Int64 = row["rowid"]
            let oldSearchText: String? = row["searchText"]
            try Self.checkItemCountersCanAdvance(db, itemID: itemID)

            let parts = [oldSearchText, title, summary].compactMap(\.self).filter { !$0.isEmpty }
            let newSearchText = String(
                parts.joined(separator: "\n").prefix(CaptureClassifier.searchTextLimit)
            )

            // `item_fts` is an external-content table: a row only exists in it
            // when the prior UPDATE that set `searchText` also inserted one,
            // which only happens for a non-empty value (see the `!capped
            // .isEmpty` guard in `attachRecognizedText`, and the ingest path
            // it mirrors). An image with no OCR text leaves `searchText ==
            // ""` — present but never indexed — so issuing the 'delete'
            // command for it targets a row that was never inserted and SQLite
            // reports that as "database disk image is malformed".
            if let oldSearchText, !oldSearchText.isEmpty {
                try db.execute(
                    sql: "INSERT INTO item_fts (item_fts, rowid, searchText) VALUES ('delete', ?, ?)",
                    arguments: [rowid, oldSearchText]
                )
            }
            try db.execute(
                sql: """
                UPDATE item SET aiTitle = ?, category = ?, aiSummary = ?, searchText = ?,
                                updatedAt = ?, lamport = lamport + 1
                WHERE id = ?
                """,
                arguments: [title, category, summary, newSearchText, Date(), itemID]
            )
            if !newSearchText.isEmpty {
                try db.execute(
                    sql: "INSERT INTO item_fts (rowid, searchText) VALUES (?, ?)",
                    arguments: [rowid, newSearchText]
                )
            }
        }
    }
}

// MARK: - Rich link metadata

public extension ClipStore {
    /// Attaches cached rich-link metadata to a `.link` item that has none yet,
    /// and folds the title + description into the FTS index so links are findable
    /// by their page title, not just their URL. Never overwrites existing
    /// metadata (`linkTitle IS NULL` guard).
    ///
    /// An empty title populates `linkTitle` (the UI treats "" as absent)
    /// but contributes nothing to FTS.
    func attachLinkMetadata(
        itemID: String,
        title: String,
        description: String?,
        faviconPNG: Data?,
        previewImagePNG: Data?
    ) async throws {
        try await self.writeCancellable { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT rowid, searchText FROM item
                WHERE id = ? AND linkTitle IS NULL AND isSecret = 0 AND deletedAt IS NULL
                """,
                arguments: [itemID]
            ) else { return }
            let rowid: Int64 = row["rowid"]
            let oldSearchText: String? = row["searchText"]
            try Self.checkItemCountersCanAdvance(db, itemID: itemID)

            // Fold the cached text into searchText so the link is findable by
            // its title/description. An empty (sentinel) title adds nothing.
            let additions = [title, description].compactMap(\.self).filter { !$0.isEmpty }
            let parts = [oldSearchText].compactMap(\.self).filter { !$0.isEmpty } + additions
            let newSearchText = parts.isEmpty
                ? nil
                : String(parts.joined(separator: "\n").prefix(CaptureClassifier.searchTextLimit))

            if let oldSearchText, !oldSearchText.isEmpty {
                try db.execute(
                    sql: "INSERT INTO item_fts (item_fts, rowid, searchText) VALUES ('delete', ?, ?)",
                    arguments: [rowid, oldSearchText]
                )
            }
            try db.execute(
                sql: """
                UPDATE item SET linkTitle = ?, linkDescription = ?, faviconData = ?,
                                previewImageData = ?, searchText = ?,
                                updatedAt = ?, lamport = lamport + 1
                WHERE id = ?
                """,
                arguments: [
                    title, description, faviconPNG, previewImagePNG, newSearchText, Date(), itemID,
                ]
            )
            if let newSearchText, !newSearchText.isEmpty {
                try db.execute(
                    sql: "INSERT INTO item_fts (rowid, searchText) VALUES (?, ?)",
                    arguments: [rowid, newSearchText]
                )
            }
        }
    }

    func linksNeedingMetadata(limit _: Int) async throws -> [ClipItem] {
        []
    }
}
