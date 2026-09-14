import Foundation
import GRDB

// MARK: - AI enrichment

public extension ClipStore {
    /// Attaches OCR'd text to an item that had none (images): becomes its
    /// searchText, enters the FTS index, and gets a semantic embedding —
    /// screenshots become findable by their contents.
    /// Empty text still sets the column (to "") so textless images are marked
    /// as attempted and don't get re-OCR'd by every backfill pass.
    func attachRecognizedText(itemID: String, text: String) async throws {
        let capped = String(text.prefix(CaptureClassifier.searchTextLimit))
        let attached: Bool = try await self.dbWriter.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT rowid, searchText FROM item WHERE id = ? AND deletedAt IS NULL",
                arguments: [itemID]
            ), (row["searchText"] as String?) == nil else { return false }

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
            return !capped.isEmpty
        }
        if attached {
            try? await self.storeEmbedding(itemID: itemID, text: capped)
        }
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
        try await self.dbWriter.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT rowid, searchText FROM item WHERE id = ? AND aiTitle IS NULL AND deletedAt IS NULL",
                arguments: [itemID]
            ) else { return }
            let rowid: Int64 = row["rowid"]
            let oldSearchText: String? = row["searchText"]

            let parts = [oldSearchText, title, summary].compactMap(\.self).filter { !$0.isEmpty }
            let newSearchText = String(
                parts.joined(separator: "\n").prefix(CaptureClassifier.searchTextLimit)
            )

            if let oldSearchText {
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
    /// Attaches fetched rich-link metadata to a `.link` item that has none yet,
    /// and folds the title + description into the FTS index so links are findable
    /// by their page title, not just their URL. Never overwrites existing
    /// metadata (`linkTitle IS NULL` guard).
    ///
    /// Failed-fetch sentinel: pass `title == ""` to mark the link as "attempted"
    /// so backfill won't retry it. The empty title still populates `linkTitle`
    /// (the UI treats "" as absent) but contributes nothing to FTS.
    func attachLinkMetadata(
        itemID: String,
        title: String,
        description: String?,
        faviconPNG: Data?,
        previewImagePNG: Data?
    ) async throws {
        try await self.dbWriter.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT rowid, searchText FROM item WHERE id = ? AND linkTitle IS NULL AND deletedAt IS NULL",
                arguments: [itemID]
            ) else { return }
            let rowid: Int64 = row["rowid"]
            let oldSearchText: String? = row["searchText"]

            // Fold the fetched text into searchText so the link is findable by
            // its title/description. An empty (sentinel) title adds nothing.
            let additions = [title, description].compactMap(\.self).filter { !$0.isEmpty }
            let parts = [oldSearchText].compactMap(\.self).filter { !$0.isEmpty } + additions
            let newSearchText = parts.isEmpty
                ? nil
                : String(parts.joined(separator: "\n").prefix(CaptureClassifier.searchTextLimit))

            if let oldSearchText {
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

    /// Live `.link` items that haven't had a metadata fetch attempted yet
    /// (`linkTitle IS NULL`), newest first, for the startup backfill pass.
    /// Secrets are excluded — their URLs never leave the machine.
    func linksNeedingMetadata(limit: Int) async throws -> [ClipItem] {
        try await self.dbWriter.read { db in
            try ClipItem
                .filter(sql: "kind = 'link' AND linkTitle IS NULL AND isSecret = 0 AND deletedAt IS NULL")
                .order(sql: "createdAt DESC")
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Clears previously-attached metadata on `.link` rows whose stored title
    /// contains `needle`, so a bad title from an earlier bug (e.g. "Sign in ・
    /// Cloudflare Access" from a Cloudflare Access login page that used to be
    /// followed and mistaken for the real page) gets re-fetched instead of
    /// staying wrong forever. Clearing `linkTitle` back to NULL re-enters the
    /// row into `linksNeedingMetadata`'s result, just like a link that was
    /// never fetched. Returns the number of rows healed.
    ///
    /// `needle` is always a constant supplied by this codebase (never
    /// user/network input), so it's interpolated into the `LIKE` pattern
    /// as-is; the query still binds it as a parameter to avoid SQL injection,
    /// it just doesn't escape `%`/`_` wildcards within it.
    func resetLinkMetadata(whereTitleContains needle: String) async throws -> Int {
        try await self.dbWriter.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT rowid, searchText, linkTitle, linkDescription FROM item
                WHERE kind = 'link' AND linkTitle LIKE '%' || ? || '%' AND deletedAt IS NULL
                """,
                arguments: [needle]
            )
            for row in rows {
                try Self.healLinkMetadataRow(db, row: row)
            }
            return rows.count
        }
    }

    /// Clears one row's fetched metadata (the per-row body of
    /// `resetLinkMetadata`, split out to keep that function short): restores
    /// `searchText` to what it held before `attachLinkMetadata` appended the
    /// title/description, and keeps the FTS index in sync with the change.
    private static func healLinkMetadataRow(_ db: GRDB.Database, row: Row) throws {
        let rowid: Int64 = row["rowid"]
        let searchText: String? = row["searchText"]
        let restoredSearchText = Self.searchText(
            beforeAttaching: row["linkTitle"], row["linkDescription"], to: searchText
        )

        if let searchText {
            try db.execute(
                sql: "INSERT INTO item_fts (item_fts, rowid, searchText) VALUES ('delete', ?, ?)",
                arguments: [rowid, searchText]
            )
        }
        try db.execute(
            sql: """
            UPDATE item SET linkTitle = NULL, linkDescription = NULL, faviconData = NULL,
                            previewImageData = NULL, searchText = ?,
                            updatedAt = ?, lamport = lamport + 1
            WHERE rowid = ?
            """,
            arguments: [restoredSearchText, Date(), rowid]
        )
        if let restoredSearchText, !restoredSearchText.isEmpty {
            try db.execute(
                sql: "INSERT INTO item_fts (rowid, searchText) VALUES (?, ?)",
                arguments: [rowid, restoredSearchText]
            )
        }
    }

    /// `attachLinkMetadata` builds `searchText` as `[oldSearchText] + [title,
    /// description]` joined by `"\n"` — this undoes exactly that append, so a
    /// link's own URL text (the pre-fetch `searchText` every `.link` item is
    /// ingested with) survives `resetLinkMetadata`, instead of the row going
    /// search-blind until the backfill re-attaches it.
    private static func searchText(beforeAttaching title: String?, _ description: String?,
                                   to searchText: String?) -> String?
    {
        let additions = [title, description].compactMap(\.self).filter { !$0.isEmpty }
        let joinedAdditions = additions.joined(separator: "\n")
        guard let searchText, !joinedAdditions.isEmpty else { return searchText }

        if searchText == joinedAdditions {
            return nil
        }
        if searchText.hasSuffix("\n" + joinedAdditions) {
            return String(searchText.dropLast(joinedAdditions.count + 1))
        }
        // Shape doesn't match what attachLinkMetadata would have produced
        // (row edited some other way) — leave searchText as-is rather than
        // guess wrong.
        return searchText
    }
}
