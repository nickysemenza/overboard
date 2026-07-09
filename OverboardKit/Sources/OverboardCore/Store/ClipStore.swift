import Foundation
import GRDB
import NaturalLanguage

/// A breakdown of the live (non-deleted) library, for the History settings tab.
public struct LibraryStats: Sendable {
    public struct KindCount: Sendable, Identifiable {
        public let kind: ItemKind
        public let count: Int
        public var id: ItemKind {
            self.kind
        }
    }

    public struct SourceCount: Sendable, Identifiable {
        public let app: String
        public let count: Int
        public var id: String {
            self.app
        }
    }

    /// One of the heaviest live items, for the storage breakdown.
    public struct LargeItem: Sendable, Identifiable {
        public let id: String
        public let kind: ItemKind
        /// Short human label — AI title, preview snippet, or the kind name.
        public let label: String
        public let byteSize: Int
    }

    public let total: Int
    /// Kinds with at least one item, most-frequent first.
    public let byKind: [KindCount]
    /// Top source apps by item count, most-frequent first.
    public let bySource: [SourceCount]
    /// The heaviest items by stored byte size, largest first.
    public let largest: [LargeItem]
}

/// The single owner of all persistence: items, representations, FTS index,
/// embeddings, and blob files. Everything mutating goes through this actor.
public actor ClipStore {
    private let dbWriter: any DatabaseWriter
    private let blobs: BlobStore
    /// Double-optional: nil = not loaded yet, .some(nil) = unavailable.
    private var embeddingCache: NLEmbedding??

    public init(dbWriter: any DatabaseWriter, blobs: BlobStore) {
        self.dbWriter = dbWriter
        self.blobs = blobs
    }

    private var sentenceEmbedding: NLEmbedding? {
        if let cached = embeddingCache { return cached }
        let embedding = NLEmbedding.sentenceEmbedding(for: .english)
        self.embeddingCache = embedding
        return embedding
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
        let stored: (item: ClipItem, isNew: Bool)? = try self.dbWriter.write { db in
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
                return (bumped, false)
            }

            // Never record where a credential came from: secrets store NULL
            // provenance even if the snapshot carried a browser URL.
            let sourceURL = classified.isSecret ? nil : snapshot.sourceURL
            let sourceTitle = classified.isSecret ? nil : snapshot.sourceTitle
            let item = ClipItem(
                contentHash: classified.contentHash,
                kind: classified.kind,
                previewText: classified.previewText,
                sourceBundleID: snapshot.sourceBundleID,
                sourceAppName: snapshot.sourceAppName,
                byteSize: classified.byteSize,
                isSecret: classified.isSecret,
                createdAt: now,
                lastUsedAt: now,
                updatedAt: now,
                charCount: classified.charCount,
                lineCount: classified.lineCount,
                pixelWidth: classified.pixelWidth,
                pixelHeight: classified.pixelHeight,
                fileCount: classified.fileCount,
                sourceURL: sourceURL,
                sourceTitle: sourceTitle
            )
            try db.execute(
                sql: """
                INSERT INTO item (id, contentHash, kind, previewText, searchText,
                                  sourceBundleID, sourceAppName, byteSize, isPinned, isSecret,
                                  useCount, createdAt, lastUsedAt, updatedAt, lamport, deletedAt,
                                  charCount, lineCount, pixelWidth, pixelHeight, fileCount,
                                  sourceURL, sourceTitle)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, 1, ?, ?, ?, 0, NULL, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    item.id, item.contentHash, item.kind.rawValue, item.previewText,
                    classified.searchText, item.sourceBundleID, item.sourceAppName,
                    item.byteSize, item.isSecret, now, now, now,
                    item.charCount, item.lineCount, item.pixelWidth, item.pixelHeight, item.fileCount,
                    item.sourceURL, item.sourceTitle,
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
            return (item, true)
        }

        guard let stored else { return nil }
        if stored.isNew, !classified.isSecret,
           classified.kind == .text || classified.kind == .link,
           let searchText = classified.searchText
        {
            // Best-effort; semantic search simply won't find this item if the
            // model is unavailable.
            try? self.storeEmbedding(itemID: stored.item.id, text: searchText)
        }
        return stored.item
    }

    // MARK: - Queries

    /// Pins first, then a gentle frecency blend: recency plus a capped bonus for
    /// reuse (`useCount`), so items you paste over and over stop scrolling away —
    /// while a brand-new copy (useCount 1, just now) still lands on top. The
    /// bonus is in julian days and saturates at useCount 8 (~7.7h of lift), so it
    /// only ever reorders near-neighbors, never buries fresh clips. `min(a, b)`
    /// is core SQLite (no math extension needed).
    static let frecencyOrderSQL =
        "isPinned DESC, (julianday(lastUsedAt) + 0.04 * min(useCount, 8)) DESC"

    public func recent(limit: Int = 100) throws -> [ClipItem] {
        try self.dbWriter.read { db in
            try ClipItem
                .filter(sql: "deletedAt IS NULL")
                .order(sql: Self.frecencyOrderSQL)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Counts of live items grouped by kind and by source app, plus the
    /// heaviest items, for the History settings tab.
    public func libraryStats(topSources: Int = 5, topLargest: Int = 5) throws -> LibraryStats {
        try self.dbWriter.read { db in
            let total = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM item WHERE deletedAt IS NULL"
            ) ?? 0

            let byKind = try Row.fetchAll(
                db,
                sql: """
                SELECT kind, COUNT(*) AS c FROM item
                WHERE deletedAt IS NULL GROUP BY kind ORDER BY c DESC
                """
            ).compactMap { row -> LibraryStats.KindCount? in
                guard let raw: String = row["kind"], let kind = ItemKind(rawValue: raw)
                else { return nil }
                return LibraryStats.KindCount(kind: kind, count: row["c"])
            }

            let bySource = try Row.fetchAll(
                db,
                sql: """
                SELECT COALESCE(NULLIF(sourceAppName, ''), 'Unknown') AS app, COUNT(*) AS c
                FROM item WHERE deletedAt IS NULL GROUP BY app ORDER BY c DESC LIMIT ?
                """,
                arguments: [topSources]
            ).map { row in
                LibraryStats.SourceCount(app: row["app"], count: row["c"])
            }

            let largest = try Row.fetchAll(
                db,
                sql: """
                SELECT id, kind, previewText, aiTitle, byteSize FROM item
                WHERE deletedAt IS NULL ORDER BY byteSize DESC LIMIT ?
                """,
                arguments: [topLargest]
            ).compactMap { row -> LibraryStats.LargeItem? in
                guard let raw: String = row["kind"], let kind = ItemKind(rawValue: raw)
                else { return nil }
                let title: String? = row["aiTitle"]
                let preview: String? = row["previewText"]
                let label = [title, preview].compactMap(\.self)
                    .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                return LibraryStats.LargeItem(
                    id: row["id"],
                    kind: kind,
                    label: label.map { String($0.prefix(60)) } ?? kind.rawValue.capitalized,
                    byteSize: row["byteSize"]
                )
            }

            return LibraryStats(total: total, byKind: byKind, bySource: bySource, largest: largest)
        }
    }

    /// FTS search ranked by bm25 blended with recency. The query may carry
    /// `kind:` / `app:` / `category:` operators (see ParsedQuery).
    public func search(_ query: String, limit: Int = 100) throws -> [ClipItem] {
        let parsed = ParsedQuery.parse(query)
        let match = FTSQuery.match(for: parsed.text)

        guard match != nil || parsed.hasFilters else { return try self.recent(limit: limit) }

        var conditions = ["item.deletedAt IS NULL"]
        var arguments: [DatabaseValueConvertible] = []
        if let kind = parsed.kind {
            conditions.append("item.kind = ?")
            arguments.append(kind.rawValue)
        }
        if let app = parsed.app {
            conditions.append("(LOWER(item.sourceAppName) LIKE ? OR LOWER(item.sourceBundleID) LIKE ?)")
            let needle = "%\(app.lowercased())%"
            arguments.append(needle)
            arguments.append(needle)
        }
        if let category = parsed.category {
            conditions.append("item.category = ?")
            arguments.append(category)
        }

        let sql: String
        if let match {
            sql = """
            SELECT item.*
            FROM item
            JOIN item_fts ON item_fts.rowid = item.rowid
            WHERE item_fts MATCH ? AND \(conditions.joined(separator: " AND "))
            ORDER BY bm25(item_fts)
                   + (julianday('now') - julianday(item.lastUsedAt)) * 0.05
            LIMIT ?
            """
            arguments.insert(match, at: 0)
        } else {
            // Filters only ("kind:image") — filtered frecency listing.
            sql = """
            SELECT item.* FROM item
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY \(Self.frecencyOrderSQL)
            LIMIT ?
            """
        }
        arguments.append(limit)

        return try self.dbWriter.read { db in
            try ClipItem.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }

    public func representations(for itemID: String) throws -> [Representation] {
        try self.dbWriter.read { db in
            try Representation
                .filter(sql: "itemID = ?", arguments: [itemID])
                .fetchAll(db)
        }
    }

    /// On-disk URL for a blob-backed representation (nil when the payload is
    /// stored inline). Lets callers stream the file — e.g. downsample a preview
    /// — without pulling a large payload fully into memory via `payload(for:)`.
    public func blobURL(for rep: Representation) -> URL? {
        guard let hash = rep.blobHash else { return nil }
        return self.blobs.url(for: hash)
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
                    ORDER BY \(Self.frecencyOrderSQL)
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

    // MARK: - Maintenance

    /// Outcome of a maintenance sweep, for logging/diagnostics.
    public struct SweepResult: Sendable, Equatable {
        /// On-disk blobs deleted because no representation referenced them
        /// (leftovers from interrupted transactions or crashes).
        public var orphanedBlobsDeleted: Int
        /// Representations whose blob file is missing — data already lost;
        /// counted so the gap is visible rather than silently failing at read.
        public var missingBlobs: Int
    }

    /// Reclaims orphaned blob files, reports representations with missing blobs,
    /// and compacts the database. Safe to run repeatedly (idempotent). Meant for
    /// startup + a daily timer; complements `purge`, which only reclaims blobs
    /// of items it deletes and can't see files left by a failed write.
    /// `async` so the compaction step below runs through GRDB's async writer
    /// rather than a synchronous actor-blocking call: VACUUM rewrites the whole
    /// file, and doing it synchronously would hold the ClipStore actor (and a
    /// cooperative-pool thread) for its full duration, stalling ingest and UI
    /// reads. The `await` releases the actor while GRDB runs it on its own writer.
    @discardableResult
    public func maintenanceSweep() async throws -> SweepResult {
        let referenced: Set<String> = try await self.dbWriter.read { db in
            try String.fetchSet(
                db,
                sql: "SELECT DISTINCT blobHash FROM representation WHERE blobHash IS NOT NULL"
            )
        }

        // On-disk files no live representation points at → safe to delete.
        let onDisk = self.blobs.allHashes()
        let orphans = onDisk.subtracting(referenced)
        var deleted = 0
        for hash in orphans where (try? self.blobs.delete(hash: hash)) != nil {
            deleted += 1
        }

        // References pointing at a file that isn't there → unrecoverable gap.
        let missing = referenced.subtracting(onDisk).count

        // Reclaim page space from purged rows; best-effort.
        // `item` has a TEXT primary key, so its rowid is the implicit one with no
        // stable INTEGER PRIMARY KEY alias. The current SQLite preserves those
        // rowids across VACUUM (verified), keeping the external-content item_fts
        // index consistent — but the docs only promise VACUUM *may* preserve them.
        // The 'rebuild' re-derives item_fts from the table afterwards as cheap
        // insurance: were a future SQLite to renumber the rowids, search would
        // otherwise silently join terms to the wrong clip. Bounded history keeps
        // the rebuild negligible next to the VACUUM it follows.
        try? await self.dbWriter.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA optimize")
            try db.execute(sql: "VACUUM")
            try db.execute(sql: "INSERT INTO item_fts(item_fts) VALUES('rebuild')")
        }

        return SweepResult(orphanedBlobsDeleted: deleted, missingBlobs: missing)
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

    // MARK: - Semantic search

    private func storeEmbedding(itemID: String, text: String) throws {
        guard let embedding = sentenceEmbedding,
              let vector = embedding.vector(for: String(text.prefix(300)))
        else { return }
        let blob = EmbeddingCoder.encode(vector)
        try self.dbWriter.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO item_embedding (itemID, vector) VALUES (?, ?)",
                arguments: [itemID, blob]
            )
        }
    }

    /// On-device semantic search over text/link items: cosine similarity of
    /// NLEmbedding sentence vectors. Complements FTS — finds "that key from
    /// AWS" when the words don't literally match.
    public func semanticSearch(
        _ query: String,
        limit: Int = 10,
        minSimilarity: Double = 0.75
    ) throws -> [ClipItem] {
        guard let embedding = sentenceEmbedding,
              let queryVector = embedding.vector(for: query)
        else { return [] }

        let rows = try self.dbWriter.read { db in
            try Row.fetchAll(db, sql: """
            SELECT e.itemID, e.vector
            FROM item_embedding e
            JOIN item i ON i.id = e.itemID
            WHERE i.deletedAt IS NULL
            """)
        }

        let query32 = queryVector.map(Float.init)
        let scored: [(id: String, score: Float)] = rows.compactMap { row in
            let vector = EmbeddingCoder.decode(row["vector"] as Data)
            guard !vector.isEmpty else { return nil }
            let score = EmbeddingCoder.cosineSimilarity(query32, vector)
            return score >= Float(minSimilarity) ? (row["itemID"] as String, score) : nil
        }

        let topIDs = scored.sorted { $0.score > $1.score }.prefix(limit).map(\.id)
        guard !topIDs.isEmpty else { return [] }

        let items = try self.dbWriter.read { db in
            try ClipItem
                .filter(sql: "deletedAt IS NULL")
                .filter(keys: topIDs)
                .fetchAll(db)
        }
        // Preserve similarity order.
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return topIDs.compactMap { byID[$0] }
    }

    // MARK: - Related

    /// K-nearest neighbours to a given item by cosine similarity of their
    /// stored embedding vectors. Excludes the item itself, other copies of
    /// the same content, secrets, and deleted items. Returns `[]` when the
    /// target has no embedding.
    public func relatedItems(
        to itemID: String,
        limit: Int = 5,
        minSimilarity: Double = 0.8
    ) throws -> [ClipItem] {
        let (target, neighbours): ([Float], [(id: String, vector: Data)]) = try self.dbWriter.read { db in
            guard let targetRow = try Row.fetchOne(db, sql: """
            SELECT i.contentHash AS contentHash, e.vector AS vector
            FROM item_embedding e
            JOIN item i ON i.id = e.itemID
            WHERE e.itemID = ?
            """, arguments: [itemID])
            else { return ([], []) }

            let targetVector = EmbeddingCoder.decode(targetRow["vector"] as Data)
            guard !targetVector.isEmpty else { return ([], []) }
            let targetHash = targetRow["contentHash"] as String

            let rows = try Row.fetchAll(db, sql: """
            SELECT e.itemID AS itemID, e.vector AS vector
            FROM item_embedding e
            JOIN item i ON i.id = e.itemID
            WHERE i.deletedAt IS NULL
              AND i.isSecret = 0
              AND e.itemID != ?
              AND i.contentHash != ?
            """, arguments: [itemID, targetHash])

            let vectors = rows.map { (id: $0["itemID"] as String, vector: $0["vector"] as Data) }
            return (targetVector, vectors)
        }

        guard !target.isEmpty else { return [] }

        let scored: [(id: String, score: Float)] = neighbours.compactMap { neighbour in
            let vector = EmbeddingCoder.decode(neighbour.vector)
            guard !vector.isEmpty else { return nil }
            let score = EmbeddingCoder.cosineSimilarity(target, vector)
            return score >= Float(minSimilarity) ? (neighbour.id, score) : nil
        }

        let topIDs = scored.sorted { $0.score > $1.score }.prefix(limit).map(\.id)
        guard !topIDs.isEmpty else { return [] }

        let items = try self.dbWriter.read { db in
            try ClipItem
                .filter(sql: "deletedAt IS NULL")
                .filter(keys: topIDs)
                .fetchAll(db)
        }
        // Preserve similarity order.
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return topIDs.compactMap { byID[$0] }
    }

    // MARK: - AI enrichment

    /// Attaches OCR'd text to an item that had none (images): becomes its
    /// searchText, enters the FTS index, and gets a semantic embedding —
    /// screenshots become findable by their contents.
    /// Empty text still sets the column (to "") so textless images are marked
    /// as attempted and don't get re-OCR'd by every backfill pass.
    public func attachRecognizedText(itemID: String, text: String) throws {
        let capped = String(text.prefix(CaptureClassifier.searchTextLimit))
        let attached: Bool = try self.dbWriter.write { db in
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
            try? self.storeEmbedding(itemID: itemID, text: capped)
        }
    }

    /// Stores generated title + category + optional summary, and folds the
    /// AI text into the FTS index so items are findable by their generated
    /// descriptions, not just their literal content. Never overwrites an
    /// existing title.
    public func attachEnrichment(
        itemID: String,
        title: String,
        category: String,
        summary: String? = nil
    ) throws {
        try self.dbWriter.write { db in
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

    // MARK: - Rich link metadata

    /// Attaches fetched rich-link metadata to a `.link` item that has none yet,
    /// and folds the title + description into the FTS index so links are findable
    /// by their page title, not just their URL. Never overwrites existing
    /// metadata (`linkTitle IS NULL` guard).
    ///
    /// Failed-fetch sentinel: pass `title == ""` to mark the link as "attempted"
    /// so backfill won't retry it. The empty title still populates `linkTitle`
    /// (the UI treats "" as absent) but contributes nothing to FTS.
    public func attachLinkMetadata(
        itemID: String,
        title: String,
        description: String?,
        faviconPNG: Data?,
        previewImagePNG: Data?
    ) throws {
        try self.dbWriter.write { db in
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
    public func linksNeedingMetadata(limit: Int) throws -> [ClipItem] {
        try self.dbWriter.read { db in
            try ClipItem
                .filter(sql: "kind = 'link' AND linkTitle IS NULL AND isSecret = 0 AND deletedAt IS NULL")
                .order(sql: "createdAt DESC")
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Secret expiry

    /// Hard-deletes secret items captured before the cutoff. Secrets are never
    /// in FTS or the embedding index, so only rows and blobs need cleanup.
    public func purgeExpiredSecrets(olderThan cutoff: Date) throws {
        let candidateHashes: Set<String> = try dbWriter.write { db in
            let victims = try String.fetchAll(
                db,
                sql: "SELECT id FROM item WHERE isSecret = 1 AND createdAt < ?",
                arguments: [cutoff]
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
                try db.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [id])
            }
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

    // MARK: - Payload helpers

    /// The plain-text payload of an item, if it has one (for transforms).
    public func plainText(for itemID: String) throws -> String? {
        let reps = try self.representations(for: itemID)
        guard let rep = reps.first(where: { $0.uti == WellKnownUTI.plainText }) else { return nil }
        return try String(data: self.payload(for: rep), encoding: .utf8)
    }

    /// Absolute filesystem paths for a `.file` clip, decoded from the stored
    /// `fileURLs` representation. Empty for non-file clips or when the payload
    /// is missing. Used by the CLI's `get` to print paths for file clips.
    public func filePaths(for itemID: String) throws -> [String] {
        let reps = try self.representations(for: itemID)
        guard let rep = reps.first(where: { $0.uti == WellKnownUTI.fileURLs }) else { return [] }
        let data = try self.payload(for: rep)
        guard let strings = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return strings.compactMap { URL(string: $0)?.path }
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

    /// Emits whenever any item or snippet changes (insert, enrichment, pin,
    /// delete, …). The value is a cheap change-counter — observers re-run
    /// their own query on each emission.
    public nonisolated func observeChangeToken() -> AsyncValueObservation<Int64> {
        ValueObservation
            .tracking { db in
                try Int64.fetchOne(db, sql: """
                SELECT (SELECT IFNULL(SUM(lamport), 0) + COUNT(*) FROM item)
                     + (SELECT IFNULL(SUM(lamport), 0) + COUNT(*) FROM snippet)
                """) ?? 0
            }
            .values(in: self.dbWriter)
    }

    /// Reactive feed of the recent list for UI. Nonisolated: GRDB observation
    /// manages its own scheduling.
    public nonisolated func observeRecent(limit: Int = 100) -> AsyncValueObservation<[ClipItem]> {
        ValueObservation
            .tracking { db in
                try ClipItem
                    .filter(sql: "deletedAt IS NULL")
                    .order(sql: Self.frecencyOrderSQL)
                    .limit(limit)
                    .fetchAll(db)
            }
            .values(in: self.dbWriter)
    }
}
