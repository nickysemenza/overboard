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
/// `reconcileOrphanBlobs`, `insertImported`), so a fresh blob can never be
/// reclaimed as an orphan between its file appearing and its row landing.
///
/// The actor's own body holds only `ingest`, payload access, and
/// change observation; snippets, queries, mutations/maintenance, semantic
/// search, enrichment, and archive export/import each live in their own
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
    /// reuse (`useCount`), so items you paste over and over stop scrolling away.
    /// The bonus is in julian days and saturates at useCount 8 (~7.7h of lift):
    /// an item reused 4+ times in the last few hours can legitimately outrank a
    /// single fresher copy — that's the design, not a mis-sort — but the cap
    /// bounds how far reuse alone can reach, so it never buries something
    /// pasted moments ago under a stale-but-frequent item. `DrawerViewModel`'s
    /// `StripEntry` flags this case for the card strip so a reorder like that
    /// reads as intentional instead of looking like a stray pin. `min(a, b)`
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
        try await self.ingest(snapshot, provenance: nil)?.item
    }

    /// The capture-path ingest. Ordered cheapest-first so a recopy of content
    /// that's already live never pays for the expensive stages:
    ///
    /// 1. classify (one SHA-256 over the representations -> `contentHash`);
    /// 2. look the hash up. A hit bumps the existing row and returns, with
    ///    no sensitivity scan, no blob hashing/writes, no provenance lookup
    ///    (an AppleScript round trip of up to 500 ms), no embedding, and
    ///    `isNew == false` so the caller skips enrichment too;
    /// 3. only for genuinely new content: the sensitivity scan (run once and
    ///    threaded through to the insert and the embedding step), provenance,
    ///    then the blob + row write.
    ///
    /// `provenance` is invoked at most once, only for new, non-secret content
    /// (secrets never record where they came from, so asking is wasted work).
    ///
    /// Blob hashes are not reused from the classifier: its hash covers the
    /// whole snapshot (kind + every representation), while a blob's name is
    /// the SHA-256 of one payload, so the two digests are of different bytes.
    /// The recopy fast path skips blob hashing entirely instead.
    ///
    /// Known trade-off: the fast path trusts the earlier scan. Identical
    /// content has an identical sensitivity label, so a recopy only re-checks
    /// the classifier's own `isSecret` (cheap, already computed), not the
    /// deeper `ClipSensitivity` scan. Content stored as non-secret by an older
    /// detector stays non-secret until a recapture of changed bytes.
    public func ingest(
        _ snapshot: PasteboardSnapshot,
        provenance: ProvenanceResolver?
    ) async throws -> IngestOutcome? {
        try Task.checkCancellation()
        try snapshot.admission?.check()
        guard var classified = CaptureClassifier.classify(snapshot) else { return nil }

        if let bumped = try await self.bumpLiveItem(
            contentHash: classified.contentHash, snapshot: snapshot, isSecret: classified.isSecret
        ) {
            return IngestOutcome(item: bumped, isNew: false)
        }

        // Computed once per capture; `insertIndexed` and `storeEmbedding`
        // receive "already screened" rather than rescanning the same text.
        if let label = ClipSensitivity.label(for: snapshot.reps) {
            classified.isSecret = true
            classified.previewText = ClipSensitivity.maskedPreview(label: label)
            classified.searchText = nil
            classified.charCount = nil
            classified.lineCount = nil
            classified.pixelWidth = nil
            classified.pixelHeight = nil
            classified.fileCount = nil
        }
        let classification = classified

        var snapshot = snapshot
        if !classification.isSecret, let found = await provenance?() {
            snapshot.sourceURL = found.url
            snapshot.sourceTitle = found.title
        }
        try Task.checkCancellation()
        try snapshot.admission?.check()
        let pending = snapshot

        let blobs = self.blobs
        let stored: (item: ClipItem, isNew: Bool)? = try await self.writeCancellable { db in
            try pending.admission?.check()
            let result = try Self.ingestWrite(db, snapshot: pending, classified: classification, blobs: blobs)
            try pending.admission?.check()
            return result
        }

        guard let stored else { return nil }
        try Task.checkCancellation()
        try snapshot.admission?.check()
        if stored.isNew, !classified.isSecret,
           classified.kind == .text || classified.kind == .link,
           let searchText = classified.searchText
        {
            // Best-effort; semantic search simply won't find this item if the
            // model is unavailable.
            try? await self.storeEmbedding(itemID: stored.item.id, text: searchText, screened: true)
        }
        return IngestOutcome(item: stored.item, isNew: stored.isNew)
    }

    /// One already-classified representation, ready to become a `Representation`
    /// row — a named type in place of a 4-member tuple.
    private struct PendingRepresentation {
        let uti: String
        let data: Data?
        let blobHash: String?
        let byteSize: Int
        let itemIndex: Int?
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
        // Re-check inside the write: another capture may have inserted the same
        // content since the fast-path read. Blobs are written only after this
        // miss, so a lost race never touches the blob store.
        if let bumped = try Self.bumpExisting(
            db, contentHash: classified.contentHash, now: now, isSecret: classified.isSecret
        ) {
            return (bumped, false)
        }

        let reps = try Self.pendingRepresentations(for: snapshot.reps, blobs: blobs)
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
                    byteSize: rep.data.count,
                    itemIndex: rep.itemIndex
                ))
            } else {
                let hash = try blobs.store(rep.data)
                reps.append(PendingRepresentation(
                    uti: rep.uti, data: nil, blobHash: hash, byteSize: rep.data.count, itemIndex: rep.itemIndex
                ))
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
        try Self.insertIndexed(db, item: item, searchText: classified.searchText, searchTextScreened: true)

        for rep in reps {
            try Representation(
                itemID: item.id,
                uti: rep.uti,
                data: rep.data,
                blobHash: rep.blobHash,
                byteSize: rep.byteSize,
                itemIndex: rep.itemIndex
            ).insert(db)
        }
        return try ClipItem.fetchOne(db, key: item.id) ?? item
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
    ///
    /// `searchTextScreened` means the caller already ran the sensitivity scan
    /// over this text's source (`ingest` scans the representations once up
    /// front and flags `item.isSecret`), so it isn't rescanned here.
    static func insertIndexed(
        _ db: GRDB.Database, item: ClipItem, searchText: String?, searchTextScreened: Bool = false
    ) throws {
        try item.insert(db)
        let searchLabel = searchTextScreened ? nil : searchText.flatMap { ClipSensitivity.label(for: $0) }
        if item.isSecret || searchLabel != nil {
            try protectSensitiveItem(
                db, itemID: item.id,
                label: searchLabel
                    ?? item.previewText.flatMap { $0.hasPrefix("Secret — ") ? String($0.dropFirst(9)) : nil }
                    ?? "Sensitive content"
            )
            return
        }
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
                .order(sql: "itemIndex ASC, rowid ASC")
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

    // MARK: - Observation

    /// Emits whenever any item or snippet changes (insert, enrichment, pin,
    /// delete, …). The value is a revision fingerprint — observers re-run
    /// their own query on each emission.
    public nonisolated func observeChangeToken() -> AsyncValueObservation<Int64> {
        ValueObservation
            .tracking { db in
                try Self.itemChangeToken(in: db)
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
