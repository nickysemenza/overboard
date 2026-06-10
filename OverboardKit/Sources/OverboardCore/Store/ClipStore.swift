import Foundation
import GRDB

/// The single owner of all persistence: items, representations, FTS index,
/// and blob files. Everything mutating goes through this actor.
public actor ClipStore {
    private let dbWriter: any DatabaseWriter
    private let blobs: BlobStore

    public init(dbWriter: any DatabaseWriter, blobs: BlobStore) {
        self.dbWriter = dbWriter
        self.blobs = blobs
    }

    // MARK: - Ingest

    /// Classifies, dedupes, and persists a snapshot.
    /// Returns the stored (or bumped) item, or nil if the snapshot was skipped.
    @discardableResult
    public func ingest(_ snapshot: PasteboardSnapshot) throws -> ClipItem? {
        guard let classified = CaptureClassifier.classify(snapshot) else { return nil }

        // Write large payloads to the blob store first. Content-addressing
        // makes this idempotent, so an orphaned blob from a failed transaction
        // is harmless and reclaimed by purge.
        var reps: [(uti: String, data: Data?, blobHash: String?, byteSize: Int)] = []
        for rep in snapshot.reps {
            if rep.data.count < Representation.inlineThreshold {
                reps.append((rep.uti, rep.data, nil, rep.data.count))
            } else {
                let hash = try blobs.store(rep.data)
                reps.append((rep.uti, nil, hash, rep.data.count))
            }
        }

        let now = snapshot.capturedAt
        return try self.dbWriter.write { db in
            // Dedupe: same content already live → bump it to the top.
            if let existing = try ClipItem
                .filter(sql: "contentHash = ? AND deletedAt IS NULL", arguments: [classified.contentHash])
                .fetchOne(db)
            {
                var bumped = existing
                bumped.useCount += 1
                bumped.lastUsedAt = now
                bumped.updatedAt = now
                bumped.lamport += 1
                try bumped.update(db)
                return bumped
            }

            let item = ClipItem(
                contentHash: classified.contentHash,
                kind: classified.kind,
                previewText: classified.previewText,
                sourceBundleID: snapshot.sourceBundleID,
                sourceAppName: snapshot.sourceAppName,
                byteSize: classified.byteSize,
                createdAt: now,
                lastUsedAt: now,
                updatedAt: now
            )
            try db.execute(
                sql: """
                INSERT INTO item (id, contentHash, kind, previewText, searchText,
                                  sourceBundleID, sourceAppName, byteSize, isPinned,
                                  useCount, createdAt, lastUsedAt, updatedAt, lamport, deletedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 1, ?, ?, ?, 0, NULL)
                """,
                arguments: [
                    item.id, item.contentHash, item.kind.rawValue, item.previewText,
                    classified.searchText, item.sourceBundleID, item.sourceAppName,
                    item.byteSize, now, now, now,
                ]
            )

            if let searchText = classified.searchText {
                let rowid = db.lastInsertedRowID
                try db.execute(
                    sql: "INSERT INTO item_fts (rowid, searchText) VALUES (?, ?)",
                    arguments: [rowid, searchText]
                )
            }

            for rep in reps {
                try Representation(
                    itemID: item.id,
                    uti: rep.uti,
                    data: rep.data,
                    blobHash: rep.blobHash,
                    byteSize: rep.byteSize
                ).insert(db)
            }
            return item
        }
    }

    // MARK: - Queries

    public func recent(limit: Int = 100) throws -> [ClipItem] {
        try self.dbWriter.read { db in
            try ClipItem
                .filter(sql: "deletedAt IS NULL")
                .order(sql: "isPinned DESC, lastUsedAt DESC")
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// FTS search ranked by bm25 blended with recency.
    public func search(_ query: String, limit: Int = 100) throws -> [ClipItem] {
        guard let match = FTSQuery.match(for: query) else { return try self.recent(limit: limit) }
        return try self.dbWriter.read { db in
            try ClipItem.fetchAll(
                db,
                sql: """
                SELECT item.*
                FROM item
                JOIN item_fts ON item_fts.rowid = item.rowid
                WHERE item_fts MATCH ? AND item.deletedAt IS NULL
                ORDER BY bm25(item_fts)
                       + (julianday('now') - julianday(item.lastUsedAt)) * 0.05
                LIMIT ?
                """,
                arguments: [match, limit]
            )
        }
    }

    public func representations(for itemID: String) throws -> [Representation] {
        try self.dbWriter.read { db in
            try Representation
                .filter(sql: "itemID = ?", arguments: [itemID])
                .fetchAll(db)
        }
    }

    /// Resolves a representation's payload, whether inline or blob-stored.
    public func payload(for rep: Representation) throws -> Data {
        if let data = rep.data { return data }
        guard let hash = rep.blobHash else {
            throw DatabaseError(message: "representation \(rep.id) has neither data nor blobHash")
        }
        return try self.blobs.data(for: hash)
    }

    // MARK: - Mutations

    public func markUsed(id: String) throws {
        try self.dbWriter.write { db in
            try db.execute(
                sql: """
                UPDATE item
                SET useCount = useCount + 1, lastUsedAt = ?, updatedAt = ?, lamport = lamport + 1
                WHERE id = ?
                """,
                arguments: [Date(), Date(), id]
            )
        }
    }

    public func setPinned(id: String, _ pinned: Bool) throws {
        try self.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE item SET isPinned = ?, updatedAt = ?, lamport = lamport + 1 WHERE id = ?",
                arguments: [pinned, Date(), id]
            )
        }
    }

    /// Tombstones an item (kept for future sync) and drops it from the FTS index.
    public func delete(id: String) throws {
        try self.dbWriter.write { db in
            try Self.removeFromFTS(db, itemID: id)
            try db.execute(
                sql: "UPDATE item SET deletedAt = ?, updatedAt = ?, lamport = lamport + 1 WHERE id = ?",
                arguments: [Date(), Date(), id]
            )
        }
    }

    /// Hard-deletes tombstones and trims history beyond `keepingLatest`
    /// (pinned items are never trimmed), then removes orphaned blobs.
    public func purge(keepingLatest: Int) throws {
        let candidateHashes: Set<String> = try dbWriter.write { db in
            let victims = try String.fetchAll(
                db,
                sql: """
                SELECT id FROM item WHERE deletedAt IS NOT NULL
                UNION
                SELECT id FROM item
                WHERE deletedAt IS NULL AND isPinned = 0 AND id NOT IN (
                    SELECT id FROM item
                    WHERE deletedAt IS NULL AND isPinned = 0
                    ORDER BY lastUsedAt DESC
                    LIMIT ?
                )
                """,
                arguments: [keepingLatest]
            )
            guard !victims.isEmpty else { return [] }

            var hashes: Set<String> = []
            for id in victims {
                let blobHashes = try String.fetchAll(
                    db,
                    sql: "SELECT blobHash FROM representation WHERE itemID = ? AND blobHash IS NOT NULL",
                    arguments: [id]
                )
                hashes.formUnion(blobHashes)
                try Self.removeFromFTS(db, itemID: id)
                try db.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [id])
            }
            // A blob is only deletable if no surviving representation references it.
            let stillReferenced = try String.fetchSet(
                db,
                sql: "SELECT DISTINCT blobHash FROM representation WHERE blobHash IS NOT NULL"
            )
            return hashes.subtracting(stillReferenced)
        }

        for hash in candidateHashes {
            try? self.blobs.delete(hash: hash)
        }
    }

    private static func removeFromFTS(_ db: GRDB.Database, itemID: String) throws {
        // Contentless-delete needs the original indexed text.
        let row = try Row.fetchOne(
            db,
            sql: "SELECT rowid, searchText FROM item WHERE id = ? AND searchText IS NOT NULL",
            arguments: [itemID]
        )
        if let row {
            try db.execute(
                sql: "INSERT INTO item_fts (item_fts, rowid, searchText) VALUES ('delete', ?, ?)",
                arguments: [row["rowid"] as Int64, row["searchText"] as String]
            )
        }
    }

    // MARK: - Snippets

    public func snippets() throws -> [Snippet] {
        try self.dbWriter.read { db in
            try Snippet
                .filter(sql: "deletedAt IS NULL")
                .order(sql: "title COLLATE NOCASE")
                .fetchAll(db)
        }
    }

    public func searchSnippets(_ query: String) throws -> [Snippet] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return try self.snippets() }
        return try self.dbWriter.read { db in
            try Snippet
                .filter(
                    sql: "deletedAt IS NULL AND (title LIKE ? OR body LIKE ?)",
                    arguments: ["%\(trimmed)%", "%\(trimmed)%"]
                )
                .order(sql: "title COLLATE NOCASE")
                .fetchAll(db)
        }
    }

    public func saveSnippet(_ snippet: Snippet) throws {
        var updated = snippet
        updated.updatedAt = Date()
        updated.lamport += 1
        try self.dbWriter.write { db in
            try updated.save(db)
        }
    }

    public func deleteSnippet(id: String) throws {
        try self.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE snippet SET deletedAt = ?, updatedAt = ?, lamport = lamport + 1 WHERE id = ?",
                arguments: [Date(), Date(), id]
            )
        }
    }

    // MARK: - Observation

    /// Reactive feed of the recent list for UI. Nonisolated: GRDB observation
    /// manages its own scheduling.
    public nonisolated func observeRecent(limit: Int = 100) -> AsyncValueObservation<[ClipItem]> {
        ValueObservation
            .tracking { db in
                try ClipItem
                    .filter(sql: "deletedAt IS NULL")
                    .order(sql: "isPinned DESC, lastUsedAt DESC")
                    .limit(limit)
                    .fetchAll(db)
            }
            .values(in: self.dbWriter)
    }
}
