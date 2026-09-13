import Foundation
import GRDB

/// A breakdown of the live (non-deleted) library, for the History settings tab.
public struct LibraryStats: Sendable {
    public struct KindCount: Sendable, Identifiable {
        public let kind: ItemKind
        public let count: Int
        public var id: ItemKind {
            self.kind
        }

        public init(kind: ItemKind, count: Int) {
            self.kind = kind
            self.count = count
        }
    }

    public struct SourceCount: Sendable, Identifiable {
        public let app: String
        public let count: Int
        public var id: String {
            self.app
        }

        public init(app: String, count: Int) {
            self.app = app
            self.count = count
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

// MARK: - Queries

public extension ClipStore {
    func recent(limit: Int = 100) async throws -> [ClipItem] {
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
    func libraryStats(topSources: Int = 5, topLargest: Int = 5) async throws -> LibraryStats {
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
    func search(_ query: String, limit: Int = 100) async throws -> [ClipItem] {
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
    func browseHistory(_ query: String, filter: ClipboardFilter = ClipboardFilter(),
                       limit: Int = 200) async throws -> [ClipItem]
    {
        let parsed = ParsedQuery.parse(query)
        let match = FTSQuery.match(for: parsed.text)
        var (conditions, arguments) = Self.browseConditions(parsed: parsed, filter: filter)

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
        let sql = """
        SELECT item.* FROM item \(join) \
        WHERE \(conditions.joined(separator: " AND ")) ORDER BY \(order) LIMIT ?
        """
        let bound = StatementArguments(arguments)
        return try await self.dbWriter.read { db in
            try ClipItem.fetchAll(db, sql: sql, arguments: bound)
        }
    }

    /// Builds `browseHistory`'s non-FTS WHERE conditions and their bound
    /// arguments (kind/source/app/category/period/pinned). Split out to keep
    /// `browseHistory` itself within the function-length limit.
    private static func browseConditions(
        parsed: ParsedQuery, filter: ClipboardFilter
    ) -> (conditions: [String], arguments: [(any DatabaseValueConvertible)?]) {
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
        if filter.pinnedOnly {
            conditions.append("item.isPinned = 1")
        }
        return (conditions, arguments)
    }

    /// FTS match excerpts for many items in one round trip — the launcher used
    /// to fetch these one row at a time (a per-row `.task`, dozens of
    /// concurrent SQLite calls while typing); it now batches every visible
    /// clip row into a single query.
    func matchExcerpts(itemIDs: [String], query: String) async throws -> [String: String] {
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
}
