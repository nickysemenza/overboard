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

    public init(path: String, name: String, root: String, generation: String, modifiedAt: Date = .distantPast, availability: FileSearchInfo.Availability = .local, isDirectory: Bool = false, location: String = "On this Mac") {
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
            availability: self.availability, isDirectory: self.isDirectory, modifiedAt: self.modifiedAt, location: self.location
        ))
    }
}

/// Rebuildable, metadata-only database, separate from irreplaceable clipboard
/// history. Trigram retrieval runs in SQLite; Swift ranks only the candidates.
public actor FileNameIndex {
    private let database: DatabaseQueue
    /// Makes `search` visible in Instruments alongside the launcher's own
    /// instant/secondary-pass intervals (`LauncherViewModel`); zero-cost when
    /// no tracing session is attached.
    private let searchSignposter = OSSignposter(subsystem: "com.nickysemenza.overboard", category: "Search")

    public init(url: URL? = nil) throws {
        self.database = try url.map { try DatabaseQueue(path: $0.path) } ?? DatabaseQueue()
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
                INSERT INTO file_fts(file_fts, rowid, foldedName, foldedPath) VALUES ('delete', old.rowid, old.foldedName, old.foldedPath);
            END;
            CREATE TRIGGER IF NOT EXISTS file_update AFTER UPDATE ON file_entry BEGIN
                INSERT INTO file_fts(file_fts, rowid, foldedName, foldedPath) VALUES ('delete', old.rowid, old.foldedName, old.foldedPath);
                INSERT INTO file_fts(rowid, foldedName, foldedPath) VALUES (new.rowid, new.foldedName, new.foldedPath);
            END;
            """)
        }
    }

    public func upsert(_ files: [IndexedFile]) throws {
        try self.database.write { db in
            for file in files {
                try file.upsert(db)
            }
        }
    }

    public func finishScan(root: String, generation: String, under path: String? = nil) throws {
        let root = root.precomposedStringWithCanonicalMapping
        let path = path?.precomposedStringWithCanonicalMapping
        try self.database.write { db in
            if let path {
                try db.execute(sql: "DELETE FROM file_entry WHERE root = ? AND generation != ? AND (path = ? OR substr(path, 1, length(?)) = ?)", arguments: [root, generation, path, path + "/", path + "/"])
            } else {
                try db.execute(sql: "DELETE FROM file_entry WHERE root = ? AND generation != ?", arguments: [root, generation])
            }
        }
    }

    public func reset() throws {
        try self.database.write { db in try db.execute(sql: "DELETE FROM file_entry") }
    }

    public func retainRoots(_ roots: [String]) throws {
        try self.database.write { db in
            let slots = Array(repeating: "?", count: roots.count).joined(separator: ",")
            try db.execute(sql: "DELETE FROM file_entry WHERE root NOT IN (\(slots))", arguments: StatementArguments(roots.map(\.precomposedStringWithCanonicalMapping)))
        }
    }

    public func count() throws -> Int {
        try self.database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM file_entry") ?? 0 }
    }

    public func search(_ query: String, limit: Int = 60) throws -> [LauncherResult] {
        let state = self.searchSignposter.beginInterval("FileNameIndex.search")
        defer { self.searchSignposter.endInterval("FileNameIndex.search", state) }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = SearchMatcher.tokens(query)
        guard !query.isEmpty else {
            return try self.database.read { db in
                try IndexedFile.fetchAll(db, sql: "SELECT * FROM file_entry ORDER BY modifiedAt DESC LIMIT ?", arguments: [limit]).map(\.result)
            }
        }
        let indexedTokens = tokens.filter { $0.count >= 3 }
        var candidates = try self.database.read { db -> [IndexedFile] in
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
                if direct.count >= limit { return direct }
                let fuzzy: String = indexedTokens.map { token -> String in
                    let chars = Array(token)
                    let grams = Set((0 ... chars.count - 3).map { String(chars[$0 ..< $0 + 3]) })
                    return "(" + grams.sorted().prefix(16).map { "\"\($0)\"" }.joined(separator: " OR ") + ")"
                }.joined(separator: " AND ")
                return try direct + retrieve(fuzzy)
            }
            let fragments = tokens.isEmpty ? [AppMatcher.fold(query)] : tokens
            let conditions = fragments.map { _ in "instr(foldedPath, ?) > 0" }.joined(separator: " AND ")
            return try IndexedFile.fetchAll(db, sql: "SELECT * FROM file_entry WHERE \(conditions) ORDER BY length(name), modifiedAt DESC LIMIT 1500", arguments: StatementArguments(fragments))
        }
        // Four-letter typos can share no trigram ("nots" -> "notes").
        // A bounded SQLite scan recovers these without widening every query.
        if tokens.count == 1, let token = tokens.first, token.count == 4 {
            let extra = try self.database.read { db in
                try IndexedFile.fetchAll(db, sql: "SELECT * FROM file_entry WHERE foldedName LIKE ? OR foldedName LIKE ? ORDER BY length(name) LIMIT 500", arguments: [String(token.prefix(2)) + "%", "%" + String(token.suffix(2)) + "%"])
            }
            candidates += extra
        }
        var seen = Set<String>()
        let prepared = SearchMatcher.PreparedQuery(query)
        return candidates.compactMap { file -> (IndexedFile, SearchMatch)? in
            guard seen.insert(file.path).inserted,
                  let tier = prepared.tier(foldedTitle: file.foldedName, foldedContext: file.foldedPath)
            else { return nil }
            return (file, SearchMatch(tier: tier))
        }.sorted { left, right in
            if left.1.tier != right.1.tier { return left.1.tier < right.1.tier }
            if left.0.name.count != right.0.name.count { return left.0.name.count < right.0.name.count }
            if left.0.modifiedAt != right.0.modifiedAt { return left.0.modifiedAt > right.0.modifiedAt }
            return left.0.path < right.0.path
        }.prefix(limit).map(\.0.result)
    }
}
