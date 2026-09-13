import Foundation
import GRDB

// MARK: - Mutations

public extension ClipStore {
    func markUsed(id: String) async throws {
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

    func setPinned(id: String, _ pinned: Bool) async throws {
        try await self.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE item SET isPinned = ?, updatedAt = ?, lamport = lamport + 1 WHERE id = ?",
                arguments: [pinned, Date(), id]
            )
        }
    }

    /// Tombstones an item (kept for future sync) and drops it from the FTS index.
    func delete(id: String) async throws {
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
    func purge(keepingLatest: Int) async throws {
        let blobs = self.blobs
        // `writeWithoutTransaction` + an explicit transaction rather than
        // `write`: the on-disk deletion must happen after the rows are gone
        // *and* while this still holds GRDB's single writer, so a concurrent
        // `ingest` can't content-address its way onto a blob that is about to
        // be unlinked.
        try await self.dbWriter.writeWithoutTransaction { db in
            let candidateHashes = try Self.purgeVictims(db, keepingLatest: keepingLatest)
            for hash in candidateHashes {
                try? blobs.delete(hash: hash)
            }
        }
    }

    /// The transactional half of `purge`: selects victims (tombstones plus
    /// live overflow beyond `keepingLatest`), removes them from FTS and the
    /// `item` table, and returns the blob hashes now safe to delete on disk.
    /// Split out to keep `purge` itself within the function-length limit.
    private static func purgeVictims(_ db: GRDB.Database, keepingLatest: Int) throws -> Set<String> {
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
                    sql: """
                    SELECT DISTINCT blobHash FROM representation \
                    WHERE itemID IN (\(placeholders)) AND blobHash IS NOT NULL
                    """,
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
        return candidateHashes
    }
}

extension ClipStore {
    /// A `?, ?, …` placeholder list for an `IN (…)` clause of `count` items.
    /// Internal (not `private`) so `ClipStore+Archive.swift`'s `exportRecords`
    /// can reach it.
    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
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
}

// MARK: - Maintenance

public extension ClipStore {
    /// Outcome of a maintenance sweep, for logging/diagnostics.
    struct SweepResult: Sendable, Equatable {
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
    func maintenanceSweep() async throws -> SweepResult {
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
}

private extension ClipStore {
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
    func reconcileOrphanBlobs() async throws -> SweepResult {
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
}

// MARK: - Secret expiry

public extension ClipStore {
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
    func purgeExpiredSecrets(olderThan cutoff: Date) async throws {
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
                        sql: """
                        SELECT DISTINCT blobHash FROM representation \
                        WHERE itemID IN (\(placeholders)) AND blobHash IS NOT NULL
                        """,
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
