import Foundation
import GRDB
import os

public struct IndexedFile: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "file_entry"
    public var path: String
    public var name: String
    public var foldedName: String
    public var foldedPath: String
    public var root: String
    public var generation: String
    public var modifiedAt: Date
    public var availability: FileSearchInfo.Availability
    public var isDirectory: Bool
    public var location: String

    public init(
        path: String,
        name: String,
        root: String,
        generation: String,
        modifiedAt: Date = .distantPast,
        availability: FileSearchInfo.Availability = .local,
        isDirectory: Bool = false,
        location: String = "On this Mac"
    ) {
        // APFS can enumerate a canonically equivalent spelling different from
        // a URL supplied by the caller. SQLite's binary keys must agree.
        self.path = path.precomposedStringWithCanonicalMapping
        self.name = name
        self.foldedName = AppMatcher.fold(name)
        self.foldedPath = AppMatcher.fold(self.path)
        self.root = root.precomposedStringWithCanonicalMapping
        self.generation = generation
        self.modifiedAt = modifiedAt
        self.availability = availability
        self.isDirectory = isDirectory
        self.location = location
    }

    public var result: LauncherResult {
        .file(name: self.name, url: URL(fileURLWithPath: self.path), info: FileSearchInfo(
            availability: self.availability, isDirectory: self.isDirectory, modifiedAt: self.modifiedAt,
            location: self.location
        ))
    }
}

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
    private let database: DatabaseQueue
    /// Makes `search` visible in Instruments alongside the launcher's own
    /// instant/secondary-pass intervals (`LauncherViewModel`); zero-cost when
    /// no tracing session is attached.
    private let searchSignposter = OSSignposter(subsystem: "com.nickysemenza.overboard", category: "Search")

    public init(url: URL? = nil) throws {
        self.database = try url.map { try DatabaseQueue(path: $0.path) } ?? DatabaseQueue()
        try self.database.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
        }
        try self.database.write { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS file_entry (
                path TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL,
                foldedName TEXT NOT NULL, foldedPath TEXT NOT NULL,
                root TEXT NOT NULL, generation TEXT NOT NULL,
                modifiedAt DATETIME NOT NULL, availability TEXT NOT NULL,
                isDirectory BOOLEAN NOT NULL, location TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS file_root ON file_entry(root, generation);
            CREATE INDEX IF NOT EXISTS file_recent ON file_entry(modifiedAt DESC);
            CREATE VIRTUAL TABLE IF NOT EXISTS file_fts USING fts5(
                foldedName, foldedPath, content='file_entry', content_rowid='rowid', tokenize='trigram'
            );
            CREATE TRIGGER IF NOT EXISTS file_insert AFTER INSERT ON file_entry BEGIN
                INSERT INTO file_fts(rowid, foldedName, foldedPath) VALUES (new.rowid, new.foldedName, new.foldedPath);
            END;
            CREATE TRIGGER IF NOT EXISTS file_delete AFTER DELETE ON file_entry BEGIN
                INSERT INTO file_fts(file_fts, rowid, foldedName, foldedPath) VALUES \
            ('delete', old.rowid, old.foldedName, old.foldedPath);
            END;
            CREATE TEMP TABLE IF NOT EXISTS file_scan_seen (
                scanID TEXT NOT NULL, path TEXT NOT NULL,
                PRIMARY KEY (scanID, path)
            ) WITHOUT ROWID;
            """)
            let updateTrigger = try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = 'file_update'"
            )
            if updateTrigger?.contains("AFTER UPDATE OF foldedName, foldedPath") != true {
                try db.execute(sql: "DROP TRIGGER IF EXISTS file_update")
                try db.execute(sql: """
                CREATE TRIGGER file_update AFTER UPDATE OF foldedName, foldedPath ON file_entry
                WHEN old.foldedName IS NOT new.foldedName OR old.foldedPath IS NOT new.foldedPath BEGIN
                    INSERT INTO file_fts(file_fts, rowid, foldedName, foldedPath) VALUES \
                ('delete', old.rowid, old.foldedName, old.foldedPath);
                    INSERT INTO file_fts(rowid, foldedName, foldedPath) VALUES \
                (new.rowid, new.foldedName, new.foldedPath);
                END;
                """)
            }
        }
    }

    /// Starts one full-root or incremental scan. Seen paths live only on this
    /// SQLite connection: they are deletion-reconciliation state, not index
    /// data, and must never turn an unchanged rescan into persistent writes.
    public func beginScan(_ scanID: String) async throws {
        try await self.database.write { db in
            try db.execute(sql: "DELETE FROM temp.file_scan_seen WHERE scanID = ?", arguments: [scanID])
        }
    }

    /// One transaction for the whole batch — the FSEvents refresh path feeds
    /// this in chunks and a per-row transaction would fsync each one. When a
    /// scan ID is supplied, paths are also recorded in the temporary seen set.
    public func upsert(_ files: [IndexedFile], seenIn scanID: String? = nil) async throws {
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
        try await self.database.write { db in try db.execute(sql: "DELETE FROM file_entry") }
    }

    public func retainRoots(_ roots: [String]) async throws {
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

    /// `@concurrent nonisolated` so the actor is held only for the SQLite
    /// fetch: the ranking pass below scores up to ~2000 rows per keystroke, and
    /// leaving it on the actor would make concurrent searches queue, while
    /// leaving it merely `nonisolated` would (under this package's
    /// `NonisolatedNonsendingByDefault` setting) run it on the launcher's main
    /// actor. Both halves therefore run on the cooperative pool.
    @concurrent
    public nonisolated func search(_ query: String, limit: Int = 60) async throws -> [LauncherResult] {
        let state = self.searchSignposter.beginInterval("FileNameIndex.search")
        defer { self.searchSignposter.endInterval("FileNameIndex.search", state) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = try await self.candidates(for: trimmed, limit: limit)
        guard !trimmed.isEmpty else { return candidates.map(\.result) }
        return Self.rank(candidates, query: trimmed, limit: limit)
    }

    /// The retrieval half of `search`: everything that touches SQLite, and
    /// nothing that doesn't. An empty query is the plain recency listing.
    private func candidates(for query: String, limit: Int) async throws -> [IndexedFile] {
        let tokens = SearchMatcher.tokens(query)
        guard !query.isEmpty else {
            return try await self.database.read { db in
                try IndexedFile.fetchAll(
                    db,
                    sql: "SELECT * FROM file_entry ORDER BY modifiedAt DESC LIMIT ?",
                    arguments: [limit]
                )
            }
        }
        let indexedTokens = tokens.filter { $0.count >= 3 }
        var candidates = try await self.database.read { db -> [IndexedFile] in
            func retrieve(_ match: String) throws -> [IndexedFile] {
                try IndexedFile.fetchAll(db, sql: """
                SELECT file_entry.* FROM file_fts JOIN file_entry ON file_entry.rowid = file_fts.rowid
                WHERE file_fts MATCH ? ORDER BY bm25(file_fts, 8.0, 1.0) LIMIT 1500
                """, arguments: [match])
            }
            if !indexedTokens.isEmpty {
                // Exact fragments first: AND intersects posting lists rather
                // than scoring every file sharing one common path trigram.
                let direct = try retrieve(indexedTokens.map { "\"\($0)\"" }.joined(separator: " AND "))
                if direct.count >= limit {
                    return direct
                }
                let fuzzy: String = indexedTokens.map { token -> String in
                    let chars = Array(token)
                    let grams = Set((0 ... chars.count - 3).map { String(chars[$0 ..< $0 + 3]) })
                    return "(" + grams.sorted().prefix(16).map { "\"\($0)\"" }.joined(separator: " OR ") + ")"
                }.joined(separator: " AND ")
                return try direct + retrieve(fuzzy)
            }
            let fragments = tokens.isEmpty ? [AppMatcher.fold(query)] : tokens
            let conditions = fragments.map { _ in "instr(foldedPath, ?) > 0" }.joined(separator: " AND ")
            return try IndexedFile.fetchAll(
                db,
                sql: "SELECT * FROM file_entry WHERE \(conditions) ORDER BY length(name), modifiedAt DESC LIMIT 1500",
                arguments: StatementArguments(fragments)
            )
        }
        // Four-letter typos can share no trigram ("nots" -> "notes").
        // A bounded SQLite scan recovers these without widening every query.
        if tokens.count == 1, let token = tokens.first, token.count == 4 {
            candidates += try await self.fourLetterTypoFallback(token)
        }
        return candidates
    }

    /// Bounded prefix/suffix LIKE scan used only for the four-letter-typo
    /// fallback above; split out to keep `candidates(for:limit:)` readable.
    private func fourLetterTypoFallback(_ token: String) async throws -> [IndexedFile] {
        try await self.database.read { db in
            try IndexedFile.fetchAll(
                db,
                sql: """
                SELECT * FROM file_entry WHERE foldedName LIKE ? OR foldedName LIKE ? \
                ORDER BY length(name) LIMIT 500
                """,
                arguments: [String(token.prefix(2)) + "%", "%" + String(token.suffix(2)) + "%"]
            )
        }
    }

    /// Scores and orders retrieved candidates. Pure — no actor state, no I/O —
    /// so it can run wherever the caller is, and is directly unit-testable.
    nonisolated static func rank(_ candidates: [IndexedFile], query: String, limit: Int) -> [LauncherResult] {
        var seen = Set<String>()
        let prepared = SearchMatcher.PreparedQuery(query)
        return candidates.compactMap { file -> (IndexedFile, SearchMatch)? in
            guard seen.insert(file.path).inserted,
                  let tier = prepared.tier(foldedTitle: file.foldedName, foldedContext: file.foldedPath)
            else { return nil }
            return (file, SearchMatch(tier: tier))
        }.sorted { left, right in
            if left.1.tier != right.1.tier {
                return left.1.tier < right.1.tier
            }
            if left.0.name.count != right.0.name.count {
                return left.0.name.count < right.0.name.count
            }
            if left.0.modifiedAt != right.0.modifiedAt {
                return left.0.modifiedAt > right.0.modifiedAt
            }
            return left.0.path < right.0.path
        }.prefix(limit).map(\.0.result)
    }
}
