import Foundation
import GRDB

extension FileNameIndex {
    /// `@concurrent nonisolated` so the actor is held only for the SQLite
    /// fetch: the ranking pass below scores up to ~2000 rows per keystroke, and
    /// leaving it on the actor would make concurrent searches queue, while
    /// leaving it merely `nonisolated` would (under this package's
    /// `NonisolatedNonsendingByDefault` setting) run it on the launcher's main
    /// actor. Both halves therefore run on the cooperative pool.
    @concurrent
    public nonisolated func search(
        _ query: String,
        limit: Int = 60,
        context: LauncherSearchContext = LauncherSearchContext()
    ) async throws -> [LauncherResult] {
        let state = self.searchSignposter.beginInterval("FileNameIndex.search")
        defer { self.searchSignposter.endInterval("FileNameIndex.search", state) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0 else { return [] }
        try Task.checkCancellation()
        let candidates = try await self.candidates(for: trimmed, limit: limit, context: context)
        try Task.checkCancellation()
        guard !trimmed.isEmpty else { return candidates.map(\.result) }
        return Self.rank(candidates, query: trimmed, limit: limit, context: context)
    }

    /// The retrieval half of `search`: everything that touches SQLite, and
    /// nothing that doesn't. An empty query is the plain recency listing.
    private func candidates(
        for query: String,
        limit: Int,
        context: LauncherSearchContext
    ) async throws -> [IndexedFile] {
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
        var candidates = try await self.database.read { db in
            try Self.retrieveCandidates(query: query, tokens: tokens, limit: limit, in: db)
        }
        // Four-letter typos can share no trigram ("nots" -> "notes").
        // A bounded SQLite scan recovers these without widening every query.
        if tokens.count == 1, let token = tokens.first, (4 ... 5).contains(token.count),
           Self.rank(candidates, query: query, limit: limit).count < limit
        {
            candidates += try await self.fourLetterTypoFallback(token)
        }
        candidates += try await self.reservedCandidates(query: query, limit: limit, context: context)
        return candidates
    }

    private static func retrieveCandidates(
        query: String,
        tokens: [String],
        limit: Int,
        in database: Database
    ) throws -> [IndexedFile] {
        let indexedTokens = tokens.filter { $0.count >= 3 }
        let prepared = SearchMatcher.PreparedQuery(query)
        if !indexedTokens.isEmpty {
            // Exact fragments first: AND intersects posting lists rather
            // than scoring every file sharing one common path trigram.
            let match = indexedTokens.map { "\"\($0)\"" }.joined(separator: " AND ")
            let direct = try Self.retrieveFTS(match, tokens: tokens, in: database)
            let validated = direct.filter {
                prepared.tier(foldedTitle: $0.foldedName, foldedContext: $0.foldedPath) != nil
            }
            if validated.count >= limit {
                return direct
            }
            let fuzzy = indexedTokens.map(Self.fuzzyClause).joined(separator: " AND ")
            return try direct + Self.retrieveFTS(fuzzy, tokens: tokens, in: database)
        }
        let fragments = SearchMatcher.literalTerm(query).map { [$0] }
            ?? (tokens.isEmpty ? [AppMatcher.fold(query)] : tokens)
        let conditions = fragments.map { _ in "instr(foldedPath, ?) > 0" }.joined(separator: " AND ")
        return try IndexedFile.fetchAll(
            database,
            sql: "SELECT * FROM file_entry WHERE \(conditions) ORDER BY length(name), modifiedAt DESC LIMIT 1500",
            arguments: StatementArguments(fragments)
        )
    }

    private static func retrieveFTS(_ match: String, tokens: [String], in database: Database) throws -> [IndexedFile] {
        let shortTokens = tokens.filter { $0.count < 3 }
        let condition = " AND (instr(file_entry.foldedName, ?) > 0 OR instr(file_entry.foldedPath, ?) > 0)"
        let conditions = shortTokens.map { _ in condition }.joined()
        return try IndexedFile.fetchAll(database, sql: """
        SELECT file_entry.* FROM file_fts JOIN file_entry ON file_entry.rowid = file_fts.rowid
        WHERE file_fts MATCH ?\(conditions) ORDER BY bm25(file_fts, 8.0, 1.0) LIMIT 1500
        """, arguments: StatementArguments([match] + shortTokens.flatMap { [$0, $0] }))
    }

    private static func fuzzyClause(_ token: String) -> String {
        let chars = Array(token)
        var grams = Set((0 ... chars.count - 3).map { String(chars[$0 ..< $0 + 3]) })
        if chars.count <= 7 {
            for position in 0 ..< chars.count - 1 {
                var swapped = chars
                swapped.swapAt(position, position + 1)
                grams.formUnion((0 ... swapped.count - 3).map { String(swapped[$0 ..< $0 + 3]) })
            }
        }
        return "(" + grams.sorted().prefix(32).map { "\"\($0)\"" }.joined(separator: " OR ") + ")"
    }

    private func reservedCandidates(
        query: String,
        limit: Int,
        context: LauncherSearchContext
    ) async throws -> [IndexedFile] {
        let needle = AppMatcher.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return try await self.database.read { db in
            var rows = try IndexedFile.fetchAll(db, sql: """
            SELECT * FROM file_entry WHERE foldedName = ? OR (foldedName >= ? AND foldedName < ?)
            ORDER BY length(name), modifiedAt DESC, path LIMIT ?
            """, arguments: [needle, needle + ".", needle + "/", max(limit, 128)])
            let paths = Self.learnedPaths(context: context)
            if !paths.isEmpty {
                let slots = Array(repeating: "?", count: paths.count).joined(separator: ",")
                rows += try IndexedFile.fetchAll(
                    db,
                    sql: "SELECT * FROM file_entry WHERE path IN (\(slots))",
                    arguments: StatementArguments(paths)
                )
            }
            return rows
        }
    }

    private static func learnedPaths(context: LauncherSearchContext) -> [String] {
        let paths = Set((Set(context.usage.keys).union(context.counts.keys)).compactMap { id in
            id.hasPrefix("file:") ? String(id.dropFirst(5)) : nil
        })
        return Array(paths.sorted { left, right in
            let leftID = "file:" + left, rightID = "file:" + right
            let leftUse = context.usage[leftID, default: 0], rightUse = context.usage[rightID, default: 0]
            if leftUse != rightUse {
                return leftUse > rightUse
            }
            let leftScore = LauncherFrecency.score(
                id: leftID, counts: context.counts, lastUsed: context.lastUsed, now: context.now
            )
            let rightScore = LauncherFrecency.score(
                id: rightID, counts: context.counts, lastUsed: context.lastUsed, now: context.now
            )
            return leftScore == rightScore ? left < right : leftScore > rightScore
        }.prefix(400))
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
    nonisolated static func rank(
        _ candidates: [IndexedFile],
        query: String,
        limit: Int,
        context: LauncherSearchContext = LauncherSearchContext()
    ) -> [LauncherResult] {
        var seen = Set<String>()
        let prepared = SearchMatcher.PreparedQuery(query)
        let matches = candidates.compactMap { file -> RankedFile? in
            guard seen.insert(file.path).inserted,
                  let tier = prepared.tier(foldedTitle: file.foldedName, foldedContext: file.foldedPath)
            else { return nil }
            let id = "file:" + file.path
            return RankedFile(
                file: file, tier: tier, usage: context.usage[id, default: 0],
                frecency: LauncherFrecency.score(
                    id: id, counts: context.counts, lastUsed: context.lastUsed, now: context.now
                )
            )
        }.sorted(by: Self.precedes)
        return matches.prefix(max(limit, 0)).map(\.file.result)
    }

    private struct RankedFile {
        let file: IndexedFile
        let tier: SearchMatch.Tier
        let usage: Int
        let frecency: Double
    }

    private nonisolated static func precedes(_ left: RankedFile, _ right: RankedFile) -> Bool {
        let leftPriority = left.usage > 0 ? 0 : left.tier.rawValue
        let rightPriority = right.usage > 0 ? 0 : right.tier.rawValue
        if leftPriority != rightPriority {
            return leftPriority < rightPriority
        }
        if left.usage != right.usage {
            return left.usage > right.usage
        }
        if left.tier != right.tier {
            return left.tier < right.tier
        }
        if left.frecency != right.frecency {
            return left.frecency > right.frecency
        }
        if left.file.name.count != right.file.name.count {
            return left.file.name.count < right.file.name.count
        }
        if left.file.modifiedAt != right.file.modifiedAt {
            return left.file.modifiedAt > right.file.modifiedAt
        }
        return left.file.path < right.file.path
    }
}
