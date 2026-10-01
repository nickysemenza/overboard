import Foundation
import GRDB
import os

/// Rebuildable, metadata-only database, separate from irreplaceable clipboard
/// history. Trigram retrieval runs in SQLite; Swift ranks only the candidates.
///
/// Every method reaches SQLite through GRDB's async API, so the actor is
/// released for the duration of each query rather than pinned to it — a
/// per-keystroke `search` no longer sits behind an FSEvents-driven `upsert`
/// batch. The actor remains because this package builds with
/// `NonisolatedNonsendingByDefault`: a nonisolated async method would run its
/// body on the caller's executor, which for the launcher is the main actor.
public actor FileNameIndex {
    let database: any DatabaseWriter
    /// Makes `search` visible in Instruments alongside the launcher's own
    /// instant/secondary-pass intervals (`LauncherViewModel`); zero-cost when
    /// no tracing session is attached.
    let searchSignposter = OSSignposter(subsystem: "com.nickysemenza.overboard", category: "Search")

    public init(url: URL? = nil) throws {
        self.database = try Self.makeDatabase(url: url)
        try Self.createSchema(in: self.database)
    }

    /// Starts one full-root or incremental scan. Seen paths live only on this
    /// SQLite connection: they are deletion-reconciliation state, not index
    /// data, and must never turn an unchanged rescan into persistent writes.
    public func beginScan(_ scanID: String) async throws {
        try Task.checkCancellation()
        try await self.database.write { db in
            try db.execute(sql: "DELETE FROM temp.file_scan_seen WHERE scanID = ?", arguments: [scanID])
        }
    }

    /// One transaction for the whole batch — the FSEvents refresh path feeds
    /// this in chunks and a per-row transaction would fsync each one. When a
    /// scan ID is supplied, paths are also recorded in the temporary seen set.
    public func upsert(_ files: [IndexedFile], seenIn scanID: String? = nil) async throws {
        for offset in stride(from: 0, to: files.count, by: 400) {
            try Task.checkCancellation()
            try await self.writeBatch(Array(files[offset ..< min(offset + 400, files.count)]), seenIn: scanID)
        }
    }

    private func writeBatch(_ files: [IndexedFile], seenIn scanID: String?) async throws {
        try await self.database.write { db in
            for file in files {
                if let scanID {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO temp.file_scan_seen (scanID, path) VALUES (?, ?)",
                        arguments: [scanID, file.path]
                    )
                }
                try db.execute(
                    sql: """
                    INSERT INTO file_entry (
                        path, name, foldedName, foldedPath, root, generation,
                        modifiedAt, availability, isDirectory, location
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(path) DO UPDATE SET
                        name = excluded.name,
                        foldedName = excluded.foldedName,
                        foldedPath = excluded.foldedPath,
                        root = excluded.root,
                        generation = excluded.generation,
                        modifiedAt = excluded.modifiedAt,
                        availability = excluded.availability,
                        isDirectory = excluded.isDirectory,
                        location = excluded.location
                    WHERE file_entry.name IS NOT excluded.name
                       OR file_entry.foldedName IS NOT excluded.foldedName
                       OR file_entry.foldedPath IS NOT excluded.foldedPath
                       OR file_entry.root IS NOT excluded.root
                       OR file_entry.modifiedAt IS NOT excluded.modifiedAt
                       OR file_entry.availability IS NOT excluded.availability
                       OR file_entry.isDirectory IS NOT excluded.isDirectory
                       OR file_entry.location IS NOT excluded.location
                    """,
                    arguments: [
                        file.path, file.name, file.foldedName, file.foldedPath,
                        file.root, file.generation, file.modifiedAt,
                        file.availability.rawValue, file.isDirectory, file.location,
                    ]
                )
            }
        }
    }

    /// Deletes entries absent from a successful scan and then releases its
    /// temporary path set. The generation column remains for on-disk schema
    /// compatibility, but deletion no longer requires rewriting it on every
    /// unchanged row.
    public func finishScan(root: String, generation: String, under path: String? = nil) async throws {
        try Task.checkCancellation()
        let root = root.precomposedStringWithCanonicalMapping
        let path = path?.precomposedStringWithCanonicalMapping
        try await self.database.write { db in
            if let path {
                try db.execute(
                    sql: """
                    DELETE FROM file_entry WHERE root = ?
                    AND (path = ? OR substr(path, 1, length(?)) = ?)
                    AND NOT EXISTS (
                        SELECT 1 FROM temp.file_scan_seen
                        WHERE scanID = ? AND file_scan_seen.path = file_entry.path
                    )
                    """,
                    arguments: [root, path, path + "/", path + "/", generation]
                )
            } else {
                try db.execute(
                    sql: """
                    DELETE FROM file_entry WHERE root = ? AND NOT EXISTS (
                        SELECT 1 FROM temp.file_scan_seen
                        WHERE scanID = ? AND file_scan_seen.path = file_entry.path
                    )
                    """,
                    arguments: [root, generation]
                )
            }
            try db.execute(
                sql: "DELETE FROM temp.file_scan_seen WHERE scanID = ?",
                arguments: [generation]
            )
        }
    }

    /// Abandons only the temporary seen set. Persistent entries already read
    /// during a partial scan remain valid, and no deletion reconciliation runs.
    public func discardScan(_ scanID: String) async throws {
        try await self.database.write { db in
            try db.execute(sql: "DELETE FROM temp.file_scan_seen WHERE scanID = ?", arguments: [scanID])
        }
    }

    public func reset() async throws {
        try Task.checkCancellation()
        try await self.database.write { db in try db.execute(sql: "DELETE FROM file_entry") }
    }

    public func retainRoots(_ roots: [String]) async throws {
        try Task.checkCancellation()
        try await self.database.write { db in
            let slots = Array(repeating: "?", count: roots.count).joined(separator: ",")
            try db.execute(
                sql: "DELETE FROM file_entry WHERE root NOT IN (\(slots))",
                arguments: StatementArguments(roots.map(\.precomposedStringWithCanonicalMapping))
            )
        }
    }

    public func count() async throws -> Int {
        try await self.database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM file_entry") ?? 0 }
    }

    public func remove(under path: String) async throws {
        try Task.checkCancellation()
        let path = path.precomposedStringWithCanonicalMapping
        try await self.database.write { db in
            try db.execute(sql: "DELETE FROM file_entry WHERE path = ? OR substr(path, 1, length(?)) = ?",
                           arguments: [path, path + "/", path + "/"])
        }
    }
}

// MARK: - Maintenance

extension FileNameIndex {
    /// Stamped into `PRAGMA user_version`. Bumping it makes every existing
    /// index run `compactIfNeeded()` once more on its next open; a freshly
    /// created index is stamped immediately since it has nothing to reclaim.
    static let maintenanceVersion = 1

    /// One-shot compaction for an index written before scans stopped rewriting
    /// every row: each of those rewrites fired the FTS trigger, and FTS5 keeps
    /// the deleted postings in its segments until a merge — so `VACUUM` alone
    /// reclaims nothing (the freelist is empty), and `'optimize'` has to merge
    /// first. Stamps `user_version` so it never runs twice; returns whether it
    /// compacted. Run before any scan holds the connection.
    public func compactIfNeeded() async throws -> Bool {
        // VACUUM can't run inside a transaction, hence `writeWithoutTransaction`.
        try await self.database.writeWithoutTransaction { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            guard version < Self.maintenanceVersion else { return false }
            try db.execute(sql: "INSERT INTO file_fts(file_fts) VALUES('optimize')")
            try db.execute(sql: "VACUUM")
            try db.execute(sql: "PRAGMA user_version = \(Self.maintenanceVersion)")
            return true
        }
    }
}
