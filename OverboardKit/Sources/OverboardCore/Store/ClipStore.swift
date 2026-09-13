import Foundation
import GRDB
import NaturalLanguage
import os

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
///
/// The actor's own body holds only `ingest`, payload access, snippets, and
/// change observation; queries, mutations/maintenance, semantic search,
/// enrichment, and archive export/import each live in their own
/// `ClipStore+Topic.swift` extension in this directory (all still part of
/// this type — extensions aren't a visibility boundary within the module,
/// just a file-size one).
public actor ClipStore {
    /// Internal (not `private`) so the `ClipStore+*.swift` extensions can
    /// reach it directly instead of needing a wrapper method per query.
    let dbWriter: any DatabaseWriter
    /// Internal (not `private`) so the `ClipStore+*.swift` extensions can
    /// reach it directly instead of needing a wrapper method per query.
    let blobs: BlobStore
    /// Double-optional: nil = not loaded yet, .some(nil) = unavailable.
    private var embeddingCache: NLEmbedding??
    /// Makes `search` visible in Instruments alongside the launcher's own
    /// instant/secondary-pass intervals (`LauncherViewModel`); zero-cost when
    /// no tracing session is attached. Internal (not `private`) so
    /// ClipStore+Search.swift's `search` can reach it.
    let searchSignposter = OSSignposter(subsystem: "com.nickysemenza.overboard", category: "Search")

    public init(dbWriter: any DatabaseWriter, blobs: BlobStore) {
        self.dbWriter = dbWriter
        self.blobs = blobs
    }

    /// Internal (not `private`) so ClipStore+Semantic.swift's `storeEmbedding`
    /// and `semanticSearch` can reach it.
    var sentenceEmbedding: NLEmbedding? {
        if let cached = embeddingCache {
            return cached
        }
        let embedding = NLEmbedding.sentenceEmbedding(for: .english)
        self.embeddingCache = embedding
        return embedding
    }

    // MARK: - Shared query ordering

    /// Pins first, then a gentle frecency blend: recency plus a capped bonus for
    /// reuse (`useCount`), so items you paste over and over stop scrolling away —
    /// while a brand-new copy (useCount 1, just now) still lands on top. The
    /// bonus is in julian days and saturates at useCount 8 (~7.7h of lift), so it
    /// only ever reorders near-neighbors, never buries fresh clips. `min(a, b)`
    /// is core SQLite (no math extension needed).
    ///
    /// Shared by ClipStore+Search.swift (`recent`, `search`),
    /// ClipStore+Maintenance.swift (`purge`), ClipStore+Archive.swift
    /// (`exportableIDs`), and `observeRecent` below.
    static let frecencyOrderSQL =
        "isPinned DESC, (julianday(lastUsedAt) + 0.04 * min(useCount, 8)) DESC"

    // MARK: - Ingest

    /// Classifies, dedupes, and persists a snapshot.
    /// Returns the stored (or bumped) item, or nil if the snapshot was skipped.
    @discardableResult
    public func ingest(_ snapshot: PasteboardSnapshot) async throws -> ClipItem? {
        guard let classified = CaptureClassifier.classify(snapshot) else { return nil }

        let blobs = self.blobs
        let stored: (item: ClipItem, isNew: Bool)? = try await self.dbWriter.write { db in
            try Self.ingestWrite(db, snapshot: snapshot, classified: classified, blobs: blobs)
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

    /// One already-classified representation, ready to become a `Representation`
    /// row — a named type in place of a 4-member tuple.
    private struct PendingRepresentation {
        let uti: String
        let data: Data?
        let blobHash: String?
        let byteSize: Int
    }

    /// `ingest`'s write-block body, split out to keep `ingest` itself within
    /// the function-length limit. Runs inside `dbWriter.write`, so this is
    /// also where the blob-before-row invariant from the type's doc comment
    /// is upheld: writing blobs here, while GRDB's single writer is held,
    /// keeps a fresh blob from being reclaimed by a concurrent `purge` or
    /// sweep before its representation row exists.
    private static func ingestWrite(
        _ db: GRDB.Database,
        snapshot: PasteboardSnapshot,
        classified: CaptureClassifier.Classified,
        blobs: BlobStore
    ) throws -> (item: ClipItem, isNew: Bool) {
        let now = snapshot.capturedAt
        let reps = try Self.pendingRepresentations(for: snapshot.reps, blobs: blobs)

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

        let item = try Self.insertNewItem(db, snapshot: snapshot, classified: classified, now: now, reps: reps)
        return (item, true)
    }

    /// Write large payloads to the blob store first. Content-addressing makes
    /// this idempotent, so an orphaned blob from a failed transaction is
    /// harmless and reclaimed by purge.
    private static func pendingRepresentations(
        for snapshotReps: [PasteboardSnapshot.Rep], blobs: BlobStore
    ) throws -> [PendingRepresentation] {
        var reps: [PendingRepresentation] = []
        for rep in snapshotReps {
            if rep.data.count < Representation.inlineThreshold {
                reps.append(PendingRepresentation(
                    uti: rep.uti,
                    data: rep.data,
                    blobHash: nil,
                    byteSize: rep.data.count
                ))
            } else {
                let hash = try blobs.store(rep.data)
                reps.append(PendingRepresentation(uti: rep.uti, data: nil, blobHash: hash, byteSize: rep.data.count))
            }
        }
        return reps
    }

    /// Builds and inserts a brand-new item (the not-a-dupe path of `ingest`),
    /// along with its representations and FTS entry.
    private static func insertNewItem(
        _ db: GRDB.Database,
        snapshot: PasteboardSnapshot,
        classified: CaptureClassifier.Classified,
        now: Date,
        reps: [PendingRepresentation]
    ) throws -> ClipItem {
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
        return item
    }

    /// The one INSERT that puts an item row *and* its FTS entry in place.
    /// `ingest` and ``import(from:)`` both go through here: `item_fts` is an
    /// external-content index that is only written explicitly, so a row
    /// inserted without this second write is
    /// invisible to `search` forever — there is no reindex to fall back on.
    /// `searchText` is a column of `item` that ``ClipItem`` deliberately doesn't
    /// model (it's derived, and enrichment rewrites it), so it's passed
    /// alongside and written here. Internal (not `private`) so
    /// `ClipStore+Archive.swift`'s `insertImported` can reach it.
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

    // MARK: - Payload helpers

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
        if let data = rep.data {
            return data
        }
        guard let hash = rep.blobHash else {
            throw DatabaseError(message: "representation \(rep.id) has neither data nor blobHash")
        }
        return try self.blobs.data(for: hash)
    }

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
