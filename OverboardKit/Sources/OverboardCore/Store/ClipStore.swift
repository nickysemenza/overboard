import Foundation
import GRDB
import NaturalLanguage
import os

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

    /// One-line library summary for the `:stats` launcher row, e.g.
    /// "1,234 items · 812 text · 96 links · 12 images". Shows the top kinds from
    /// `byKind` (already most-frequent first); no byte total.
    public var subtitle: String {
        var parts = [CountPhrase.string(self.total, of: String(localized: "item"))]
        for kindCount in self.byKind.prefix(3) {
            parts.append(kindCount.kind.countLabel(kindCount.count))
        }
        return parts.joined(separator: " · ")
    }
}

/// The single owner of all persistence: items, representations, FTS index,
/// embeddings, and blob files. Everything mutating goes through this actor.
///
/// Still an actor, but for its *executor*, not for exclusion. Every query and
/// mutation now goes through GRDB's async API, so the actor is released the
/// moment the I/O starts: an `ingest` no longer pins the actor (and a
/// cooperative-pool thread) for the whole write, and a `search` typed
/// underneath it enters immediately and runs on one of `DatabasePool`'s WAL
/// readers alongside it. The actor survives the conversion because this package
/// builds with `NonisolatedNonsendingByDefault` — a plain `Sendable` final
/// class would run each method's body (capture classification, cosine scoring,
/// blob file reads) on the *caller's* executor, which for the launcher, drawer,
/// and every intent is the main actor. Actor isolation is what keeps that work
/// off the main thread; `embeddingCache` is the only mutable state it guards.
///
/// What the old synchronous bodies got for free is now explicit: since every
/// method suspends, actor atomicity no longer separates blob writes from blob
/// deletions. GRDB's single writer does that instead — **every blob-file
/// mutation happens inside a `dbWriter` write block** (`ingest`, `purge`,
/// `purgeExpiredSecrets`, `reconcileOrphanBlobs`, `insertImported`), so a fresh blob can never be
/// reclaimed as an orphan between its file appearing and its row landing.
public actor ClipStore {
    private let dbWriter: any DatabaseWriter
    private let blobs: BlobStore
    /// Double-optional: nil = not loaded yet, .some(nil) = unavailable.
    private var embeddingCache: NLEmbedding??
    /// Makes `search` visible in Instruments alongside the launcher's own
    /// instant/secondary-pass intervals (`LauncherViewModel`); zero-cost when
    /// no tracing session is attached.
    private let searchSignposter = OSSignposter(subsystem: "com.nickysemenza.overboard", category: "Search")

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
    public func ingest(_ snapshot: PasteboardSnapshot) async throws -> ClipItem? {
        guard let classified = CaptureClassifier.classify(snapshot) else { return nil }

        let now = snapshot.capturedAt
        let blobs = self.blobs
        let snapshotReps = snapshot.reps
        let stored: (item: ClipItem, isNew: Bool)? = try await self.dbWriter.write { db in
            // Write large payloads to the blob store first. Content-addressing
            // makes this idempotent, so an orphaned blob from a failed transaction
            // is harmless and reclaimed by purge. Inside the write block on
            // purpose: holding GRDB's single writer is what now keeps a fresh
            // blob from being reclaimed by a concurrent `purge` or sweep before
            // its representation row exists (see the type's doc comment).
            var reps: [(uti: String, data: Data?, blobHash: String?, byteSize: Int)] = []
            for rep in snapshotReps {
                if rep.data.count < Representation.inlineThreshold {
                    reps.append((rep.uti, rep.data, nil, rep.data.count))
                } else {
                    let hash = try blobs.store(rep.data)
                    reps.append((rep.uti, nil, hash, rep.data.count))
                }
            }

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
            try Self.insertIndexed(db, item: item, searchText: classified.searchText)

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
            try? await self.storeEmbedding(itemID: stored.item.id, text: searchText)
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

    public func recent(limit: Int = 100) async throws -> [ClipItem] {
        try await self.dbWriter.read { db in
            try ClipItem
                .filter(sql: "deletedAt IS NULL")
                .order(sql: Self.frecencyOrderSQL)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Counts of live items grouped by kind and by source app, plus the
    /// heaviest items, for the History settings tab.
    public func libraryStats(topSources: Int = 5, topLargest: Int = 5) async throws -> LibraryStats {
        try await self.dbWriter.read { db in
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
    public func search(_ query: String, limit: Int = 100) async throws -> [ClipItem] {
        let state = self.searchSignposter.beginInterval("ClipStore.search")
        defer { self.searchSignposter.endInterval("ClipStore.search", state) }
        let parsed = ParsedQuery.parse(query)
        let match = FTSQuery.match(for: parsed.text)

        guard match != nil || parsed.hasFilters else { return try await self.recent(limit: limit) }

        var conditions = ["item.deletedAt IS NULL"]
        // Optional element type so `StatementArguments(_:)` below resolves to the
        // non-failable initializer without a contextual type to steer it.
        var arguments: [(any DatabaseValueConvertible)?] = []
        if let literal = SearchMatcher.literalTerm(parsed.text) {
            conditions.append("instr(LOWER(item.searchText), ?) > 0")
            arguments.append(literal)
        }
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

        // `arguments` is an array of existentials; bind it before the closure so
        // only the `Sendable` StatementArguments crosses into GRDB's reader.
        let bound = StatementArguments(arguments)
        return try await self.dbWriter.read { db in
            try ClipItem.fetchAll(db, sql: sql, arguments: bound)
        }
    }

    /// Browser filters are applied before LIMIT, including OCR-backed FTS hits.
    public func browseHistory(_ query: String, filter: ClipboardFilter = ClipboardFilter(), limit: Int = 200) async throws -> [ClipItem] {
        let parsed = ParsedQuery.parse(query)
        let match = FTSQuery.match(for: parsed.text)
        var conditions = ["item.deletedAt IS NULL", "item.isSecret = 0"]
        // Optional element type so `StatementArguments(_:)` below resolves to the
        // non-failable initializer without a contextual type to steer it.
        var arguments: [(any DatabaseValueConvertible)?] = []
        if let literal = SearchMatcher.literalTerm(parsed.text) {
            conditions.append("instr(LOWER(item.searchText), ?) > 0")
            arguments.append(literal)
        }
        if let kind = filter.kind ?? parsed.kind {
            conditions.append("item.kind = ?")
            arguments.append(kind.rawValue)
        }
        if let source = filter.source {
            conditions.append("item.sourceAppName = ?")
            arguments.append(source)
        }
        if let app = parsed.app {
            conditions.append("(LOWER(item.sourceAppName) LIKE ? OR LOWER(item.sourceBundleID) LIKE ?)")
            arguments += ["%\(app.lowercased())%", "%\(app.lowercased())%"]
        }
        if let category = parsed.category {
            conditions.append("item.category = ?")
            arguments.append(category)
        }
        if let since = filter.period.cutoff() {
            conditions.append("item.lastUsedAt >= ?")
            arguments.append(since)
        }
        if filter.pinnedOnly { conditions.append("item.isPinned = 1") }
        let join: String
        let order: String
        if let match {
            join = "JOIN item_fts ON item_fts.rowid = item.rowid"
            conditions.insert("item_fts MATCH ?", at: 0)
            arguments.insert(match, at: 0)
            order = "bm25(item_fts), item.lastUsedAt DESC"
        } else {
            guard parsed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            join = ""
            order = "item.lastUsedAt DESC"
        }
        arguments.append(limit)
        let sql = "SELECT item.* FROM item \(join) WHERE \(conditions.joined(separator: " AND ")) ORDER BY \(order) LIMIT ?"
        let bound = StatementArguments(arguments)
        return try await self.dbWriter.read { db in
            try ClipItem.fetchAll(db, sql: sql, arguments: bound)
        }
    }

    /// FTS match excerpts for many items in one round trip — the launcher used
    /// to fetch these one row at a time (a per-row `.task`, dozens of
    /// concurrent SQLite calls while typing); it now batches every visible
    /// clip row into a single query.
    public func matchExcerpts(itemIDs: [String], query: String) async throws -> [String: String] {
        guard !itemIDs.isEmpty, let match = FTSQuery.match(for: ParsedQuery.parse(query).text) else { return [:] }
        let placeholders = Array(repeating: "?", count: itemIDs.count).joined(separator: ",")
        return try await self.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT item.id AS id, snippet(item_fts, 0, '', '', ' … ', 18) AS excerpt
            FROM item_fts JOIN item ON item.rowid = item_fts.rowid
            WHERE item_fts MATCH ? AND item.id IN (\(placeholders)) AND item.isSecret = 0 AND item.deletedAt IS NULL
            """, arguments: StatementArguments([match] + itemIDs))
            var excerpts: [String: String] = [:]
            for row in rows {
                if let id: String = row["id"], let excerpt: String = row["excerpt"] {
                    excerpts[id] = excerpt
                }
            }
            return excerpts
        }
    }

    public func representations(for itemID: String) async throws -> [Representation] {
        try await self.dbWriter.read { db in
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

    public func markUsed(id: String) async throws {
        try await self.dbWriter.write { db in
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

    public func setPinned(id: String, _ pinned: Bool) async throws {
        try await self.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE item SET isPinned = ?, updatedAt = ?, lamport = lamport + 1 WHERE id = ?",
                arguments: [pinned, Date(), id]
            )
        }
    }

    /// Tombstones an item (kept for future sync) and drops it from the FTS index.
    public func delete(id: String) async throws {
        try await self.dbWriter.write { db in
            try Self.removeFromFTS(db, itemID: id)
            try db.execute(
                sql: "UPDATE item SET deletedAt = ?, updatedAt = ?, lamport = lamport + 1 WHERE id = ?",
                arguments: [Date(), Date(), id]
            )
        }
    }

    /// Hard-deletes tombstones and trims history beyond `keepingLatest`
    /// (pinned items are never trimmed), then removes orphaned blobs.
    public func purge(keepingLatest: Int) async throws {
        let blobs = self.blobs
        // `writeWithoutTransaction` + an explicit transaction rather than
        // `write`: the on-disk deletion must happen after the rows are gone
        // *and* while this still holds GRDB's single writer, so a concurrent
        // `ingest` can't content-address its way onto a blob that is about to
        // be unlinked.
        try await self.dbWriter.writeWithoutTransaction { db in
            var candidateHashes: Set<String> = []
            try db.inTransaction {
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
                guard !victims.isEmpty else { return .commit }

                // Batched blob lookup + delete instead of a per-victim round trip:
                // history can hold thousands of tombstones/overflow rows, and a
                // purge used to issue two queries per row. Chunked at 500 to stay
                // under SQLite's default ~999 bound-parameter limit.
                var hashes: Set<String> = []
                for chunk in victims.chunked(into: 500) {
                    let placeholders = Self.placeholders(chunk.count)
                    let chunkHashes = try String.fetchAll(
                        db,
                        sql: "SELECT DISTINCT blobHash FROM representation WHERE itemID IN (\(placeholders)) AND blobHash IS NOT NULL",
                        arguments: StatementArguments(chunk)
                    )
                    hashes.formUnion(chunkHashes)
                }

                // FTS removal needs each row's own (rowid, searchText) pair for the
                // contentless-delete command, so it stays one call per victim.
                for id in victims {
                    try Self.removeFromFTS(db, itemID: id)
                }

                for chunk in victims.chunked(into: 500) {
                    let placeholders = Self.placeholders(chunk.count)
                    try db.execute(
                        sql: "DELETE FROM item WHERE id IN (\(placeholders))",
                        arguments: StatementArguments(chunk)
                    )
                }
                // A blob is only deletable if no surviving representation references it.
                let stillReferenced = try String.fetchSet(
                    db,
                    sql: "SELECT DISTINCT blobHash FROM representation WHERE blobHash IS NOT NULL"
                )
                candidateHashes = hashes.subtracting(stillReferenced)
                return .commit
            }

            for hash in candidateHashes {
                try? blobs.delete(hash: hash)
            }
        }
    }

    /// A `?, ?, …` placeholder list for an `IN (…)` clause of `count` items.
    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
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
    @discardableResult
    public func maintenanceSweep() async throws -> SweepResult {
        let result = try await self.reconcileOrphanBlobs()

        // Reclaim page space from purged rows; best-effort. The VACUUM touches no
        // blob files, so releasing the actor here is safe.
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
        return result
    }

    /// Deletes on-disk blobs no live representation references, and counts
    /// references whose file is missing. The whole read → delete pass runs
    /// inside `writeWithoutTransaction`, holding GRDB's single writer: were it
    /// to suspend between reading the referenced set and deleting orphans, a
    /// concurrent `ingest` could write a new blob + representation in the gap —
    /// and that fresh blob, present on disk but absent from the now-stale
    /// referenced set, would be deleted as an orphan, corrupting the
    /// just-captured clip. `ingest` writes its blobs inside its own write block,
    /// so the writer queue is what serialises the two. No transaction is opened:
    /// this reads rows and mutates only files.
    private func reconcileOrphanBlobs() async throws -> SweepResult {
        let blobs = self.blobs
        return try await self.dbWriter.writeWithoutTransaction { db in
            let referenced = try String.fetchSet(
                db,
                sql: "SELECT DISTINCT blobHash FROM representation WHERE blobHash IS NOT NULL"
            )

            // On-disk files no live representation points at → safe to delete.
            let onDisk = blobs.allHashes()
            let orphans = onDisk.subtracting(referenced)
            var deleted = 0
            for hash in orphans where (try? blobs.delete(hash: hash)) != nil {
                deleted += 1
            }

            // References pointing at a file that isn't there → unrecoverable gap.
            let missing = referenced.subtracting(onDisk).count

            return SweepResult(orphanedBlobsDeleted: deleted, missingBlobs: missing)
        }
    }

    /// The one INSERT that puts an item row *and* its FTS entry in place.
    /// `ingest` and ``import(from:)`` both go through here: `item_fts` is an
    /// external-content index that is only written explicitly, so a row
    /// inserted without this second write is
    /// invisible to `search` forever — there is no reindex to fall back on.
    /// `searchText` is a column of `item` that ``ClipItem`` deliberately doesn't
    /// model (it's derived, and enrichment rewrites it), so it's passed
    /// alongside and written here.
    static func insertIndexed(_ db: GRDB.Database, item: ClipItem, searchText: String?) throws {
        try item.insert(db)
        guard let searchText else { return }
        let rowid = db.lastInsertedRowID
        try db.execute(
            sql: "UPDATE item SET searchText = ? WHERE rowid = ?",
            arguments: [searchText, rowid]
        )
        try db.execute(
            sql: "INSERT INTO item_fts (rowid, searchText) VALUES (?, ?)",
            arguments: [rowid, searchText]
        )
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

    private func storeEmbedding(itemID: String, text: String) async throws {
        guard let embedding = sentenceEmbedding,
              let vector = embedding.vector(for: String(text.prefix(300)))
        else { return }
        let blob = EmbeddingCoder.encode(vector)
        try await self.dbWriter.write { db in
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
    ) async throws -> [ClipItem] {
        guard let embedding = sentenceEmbedding,
              let queryVector = embedding.vector(for: query)
        else { return [] }

        // Capped to the 1000 most recently used items rather than scoring the
        // whole embedding table in Swift: recent items are what people
        // actually search for, and the cap bounds memory at ~3 MB (1000 ×
        // ~768 dims × 4 bytes) regardless of how large history grows.
        // GRDB `Row`s are not `Sendable`, so they are projected onto plain
        // values inside the closure rather than handed back across it.
        let rows: [(id: String, vector: Data)] = try await self.dbWriter.read { db in
            try Row.fetchAll(db, sql: """
            SELECT e.itemID, e.vector
            FROM item_embedding e
            JOIN item i ON i.id = e.itemID
            WHERE i.deletedAt IS NULL
            ORDER BY i.lastUsedAt DESC
            LIMIT 1000
            """).map { (id: $0["itemID"] as String, vector: $0["vector"] as Data) }
        }

        let query32 = queryVector.map(Float.init)
        let scored: [(id: String, score: Float)] = rows.compactMap { row in
            let vector = EmbeddingCoder.decode(row.vector)
            guard !vector.isEmpty else { return nil }
            let score = EmbeddingCoder.cosineSimilarity(query32, vector)
            return score >= Float(minSimilarity) ? (row.id, score) : nil
        }

        let topIDs = scored.sorted { $0.score > $1.score }.prefix(limit).map(\.id)
        guard !topIDs.isEmpty else { return [] }

        let items = try await self.dbWriter.read { db in
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
    ) async throws -> [ClipItem] {
        let (target, neighbours): ([Float], [(id: String, vector: Data)]) = try await self.dbWriter.read { db in
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

            // Same 1000-item recency cap as `semanticSearch` — see its comment.
            let rows = try Row.fetchAll(db, sql: """
            SELECT e.itemID AS itemID, e.vector AS vector
            FROM item_embedding e
            JOIN item i ON i.id = e.itemID
            WHERE i.deletedAt IS NULL
              AND i.isSecret = 0
              AND e.itemID != ?
              AND i.contentHash != ?
            ORDER BY i.lastUsedAt DESC
            LIMIT 1000
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

        let items = try await self.dbWriter.read { db in
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
    public func attachRecognizedText(itemID: String, text: String) async throws {
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
    public func attachEnrichment(
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
    public func linksNeedingMetadata(limit: Int) async throws -> [ClipItem] {
        try await self.dbWriter.read { db in
            try ClipItem
                .filter(sql: "kind = 'link' AND linkTitle IS NULL AND isSecret = 0 AND deletedAt IS NULL")
                .order(sql: "createdAt DESC")
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Secret expiry

    /// Hard-deletes expired secret items. Secrets are never in FTS or the
    /// embedding index, so only rows and blobs need cleanup. The delete is real
    /// rather than a tombstone on purpose — the point of the sweep is to get
    /// secret cleartext off disk, and a tombstoned row would keep its blobs.
    ///
    /// Two carve-outs keep the sweep from destroying data the user asked to
    /// keep. Pinned items are spared outright: pinning is an explicit "keep
    /// this", and honouring it costs less than silently deleting a
    /// false-positive match. And the cutoff runs from the later of capture and
    /// last use, so the TTL is a leash on *idle* secrets — an item you keep
    /// pasting stays until ten minutes after you stop.
    public func purgeExpiredSecrets(olderThan cutoff: Date) async throws {
        let blobs = self.blobs
        // Same writer-held shape as `purge`: rows first, then the files, all
        // without letting go of GRDB's single writer.
        try await self.dbWriter.writeWithoutTransaction { db in
            var candidateHashes: Set<String> = []
            try db.inTransaction {
                let victims = try String.fetchAll(
                    db,
                    sql: """
                    SELECT id FROM item
                    WHERE isSecret = 1 AND isPinned = 0 AND max(createdAt, lastUsedAt) < ?
                    """,
                    arguments: [cutoff]
                )
                guard !victims.isEmpty else { return .commit }

                // Same batching as `purge`: one blob lookup and one delete per
                // 500-id chunk instead of two queries per victim.
                var hashes: Set<String> = []
                for chunk in victims.chunked(into: 500) {
                    let placeholders = Self.placeholders(chunk.count)
                    let chunkHashes = try String.fetchAll(
                        db,
                        sql: "SELECT DISTINCT blobHash FROM representation WHERE itemID IN (\(placeholders)) AND blobHash IS NOT NULL",
                        arguments: StatementArguments(chunk)
                    )
                    hashes.formUnion(chunkHashes)
                }
                for chunk in victims.chunked(into: 500) {
                    let placeholders = Self.placeholders(chunk.count)
                    try db.execute(
                        sql: "DELETE FROM item WHERE id IN (\(placeholders))",
                        arguments: StatementArguments(chunk)
                    )
                }
                let stillReferenced = try String.fetchSet(
                    db,
                    sql: "SELECT DISTINCT blobHash FROM representation WHERE blobHash IS NOT NULL"
                )
                candidateHashes = hashes.subtracting(stillReferenced)
                return .commit
            }

            for hash in candidateHashes {
                try? blobs.delete(hash: hash)
            }
        }
    }

    // MARK: - Payload helpers

    /// The plain-text payload of an item, if it has one (for transforms).
    public func plainText(for itemID: String) async throws -> String? {
        let reps = try await self.representations(for: itemID)
        guard let rep = reps.first(where: { $0.uti == WellKnownUTI.plainText }) else { return nil }
        return try String(data: self.payload(for: rep), encoding: .utf8)
    }

    /// Absolute filesystem paths for a `.file` clip, decoded from the stored
    /// `fileURLs` representation. Empty for non-file clips or when the payload
    /// is missing. Used by the CLI's `get` to print paths for file clips.
    public func filePaths(for itemID: String) async throws -> [String] {
        let reps = try await self.representations(for: itemID)
        guard let rep = reps.first(where: { $0.uti == WellKnownUTI.fileURLs }) else { return [] }
        let data = try self.payload(for: rep)
        guard let strings = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return strings.compactMap { URL(string: $0)?.path }
    }

    // MARK: - Snippets

    public func snippets() async throws -> [Snippet] {
        try await self.dbWriter.read { db in
            try Snippet
                .filter(sql: "deletedAt IS NULL")
                .order(sql: "title COLLATE NOCASE")
                .fetchAll(db)
        }
    }

    public func searchSnippets(_ query: String) async throws -> [Snippet] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return try await self.snippets() }
        return try await self.dbWriter.read { db in
            try Snippet
                .filter(
                    sql: "deletedAt IS NULL AND (title LIKE ? OR body LIKE ?)",
                    arguments: ["%\(trimmed)%", "%\(trimmed)%"]
                )
                .order(sql: "title COLLATE NOCASE")
                .fetchAll(db)
        }
    }

    public func saveSnippet(_ snippet: Snippet) async throws {
        var updated = snippet
        updated.updatedAt = Date()
        updated.lamport += 1
        let record = updated
        try await self.dbWriter.write { db in
            try record.save(db)
        }
    }

    public func deleteSnippet(id: String) async throws {
        try await self.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE snippet SET deletedAt = ?, updatedAt = ?, lamport = lamport + 1 WHERE id = ?",
                arguments: [Date(), Date(), id]
            )
        }
    }

    // MARK: - Archive support

    //
    // The store-side half of `ClipArchive.swift`: everything that needs the
    // private `dbWriter` / `blobs` lives here, the format itself lives there.

    /// Live item ids in frecency order, so an archive reads top-of-history
    /// first. `secretClause` is a caller-built SQL fragment (`""` or
    /// `" AND isSecret = 0"`), never user input.
    func exportableIDs(secretClause: String) async throws -> [String] {
        try await self.dbWriter.read { db in
            try String.fetchAll(db, sql: """
            SELECT id FROM item WHERE deletedAt IS NULL\(secretClause)
            ORDER BY \(Self.frecencyOrderSQL)
            """)
        }
    }

    func liveSecretCount() async throws -> Int {
        try await self.dbWriter.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM item WHERE deletedAt IS NULL AND isSecret = 1"
            ) ?? 0
        }
    }

    /// Archive records for `ids`, in the order given.
    func exportRecords(ids: [String]) async throws -> [ClipArchive.Record] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Self.placeholders(ids.count)
        return try await self.dbWriter.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM item WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
            let reps = try Representation.fetchAll(
                db,
                sql: "SELECT * FROM representation WHERE itemID IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
            let repsByItem = Dictionary(grouping: reps, by: \.itemID)
            var byID: [String: ClipArchive.Record] = [:]
            for row in rows {
                let item = try ClipItem(row: row)
                byID[item.id] = ClipArchive.Record(
                    item: item,
                    searchText: row["searchText"],
                    representations: repsByItem[item.id] ?? []
                )
            }
            return ids.compactMap { byID[$0] }
        }
    }

    /// The archive's copy source for a blob, or nil when the file is gone.
    func blobFileURL(for hash: String) -> URL? {
        let url = self.blobs.url(for: hash)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Inserts one archived record, skipping it when its content is already
    /// live. Blob payloads are re-stored inside the write block for the same
    /// reason `ingest` does it there: holding GRDB's single writer is what keeps
    /// a concurrent `purge` from reclaiming a fresh blob before its row lands.
    func insertImported(
        record: ClipArchive.Record, payloads: [ArchivePayload]
    ) async throws -> ImportOutcome {
        let blobs = self.blobs
        return try await self.dbWriter.write { db in
            let isDuplicate = try ClipItem
                .filter(sql: "contentHash = ? AND deletedAt IS NULL", arguments: [record.contentHash])
                .fetchCount(db) > 0
            guard !isDuplicate else { return .duplicate }

            // Keep the archived id when it's free — it's the handle a user may
            // have in a script or an export diff — but an id can still be taken
            // by a tombstone the contentHash check above doesn't see.
            let taken = try ClipItem.filter(key: record.id).fetchCount(db) > 0
            let id = taken ? UUID().uuidString : record.id
            guard let item = record.clipItem(id: id) else { return .malformed }

            try Self.insertIndexed(db, item: item, searchText: record.searchText)
            for payload in payloads {
                // Same inline/blob split as capture, re-derived rather than
                // trusted from the archive, so one rule decides where payloads live.
                let inline = payload.bytes.count < Representation.inlineThreshold
                try Representation(
                    itemID: id,
                    uti: payload.uti,
                    data: inline ? payload.bytes : nil,
                    blobHash: inline ? nil : blobs.store(payload.bytes),
                    byteSize: payload.bytes.count
                ).insert(db)
            }
            return .inserted(id)
        }
    }

    /// `storeEmbedding` for callers outside this file (the importer), with the
    /// same best-effort contract: a missing model costs semantic hits, nothing else.
    func storeEmbeddingIfPossible(itemID: String, text: String) async throws {
        try await self.storeEmbedding(itemID: itemID, text: text)
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

private extension Array {
    /// Splits into consecutive slices of at most `size` elements each — used
    /// to keep batched `IN (…)` queries under SQLite's bound-parameter limit.
    func chunked(into size: Int) -> [[Element]] {
        guard !isEmpty else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
