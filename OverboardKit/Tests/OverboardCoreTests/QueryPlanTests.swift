import Foundation
import GRDB
@testable import OverboardCore
import Testing

/// Verifies the v6 partial indexes (`item_live_recent`, `item_live_kind`)
/// actually change SQLite's query plan for the query shapes `ClipStore`
/// issues in its real listings — not just that the indexes exist in the
/// schema. Each test's plan was captured once against a live SQLite build and
/// the assertions below are pinned to what actually holds; where SQLite still
/// prefers a scan (documented per test), that's asserted as the observed
/// baseline rather than silently ignored.
struct QueryPlanTests {
    private func makeQueue() throws -> DatabaseQueue {
        try OverboardDatabase.openInMemory()
    }

    private func seed(
        _ queue: DatabaseQueue,
        id: String,
        kind: String = "text",
        isPinned: Bool = false,
        deleted: Bool = false,
        lastUsedAt: Date = Date()
    ) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO item
                  (id, contentHash, kind, previewText, byteSize, isPinned, isSecret,
                   useCount, createdAt, lastUsedAt, updatedAt, deletedAt)
                VALUES (?, ?, ?, 'text', 1, ?, 0, 1, ?, ?, ?, ?)
                """,
                arguments: [
                    id, id, kind, isPinned, lastUsedAt, lastUsedAt, lastUsedAt,
                    deleted ? lastUsedAt : nil,
                ]
            )
        }
    }

    /// `EXPLAIN QUERY PLAN` rows, flattened to their `detail` text (SQLite's
    /// human-readable plan line, e.g. `"SEARCH item USING INDEX … (kind=?)"`).
    private func plan(
        _ queue: DatabaseQueue,
        sql: String,
        arguments: StatementArguments = StatementArguments()
    ) throws -> [String] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)", arguments: arguments)
                .map { $0["detail"] as String }
        }
    }

    /// `recent()`'s query: `WHERE deletedAt IS NULL ORDER BY <frecency>`. The
    /// filter benefits from `item_live_recent` (observed plan: `["SCAN item
    /// USING INDEX item_live_recent", "USE TEMP B-TREE FOR ORDER BY"]`) — but
    /// the ORDER BY is a computed expression
    /// (`julianday(lastUsedAt) + 0.04*min(useCount,8)`), which no plain
    /// column index (partial or not) can satisfy, so SQLite still needs a
    /// temp B-tree to sort. Per the plan: that's documented here rather than
    /// "fixed" with an expression index that isn't demonstrably justified.
    @Test func recentQueryPlan() throws {
        let queue = try makeQueue()
        for index in 0 ..< 20 {
            try self.seed(queue, id: "item-\(index)")
        }

        let sql = "SELECT * FROM item WHERE deletedAt IS NULL ORDER BY \(ClipStore.frecencyOrderSQL) LIMIT ?"
        let plan = try self.plan(queue, sql: sql, arguments: [100])

        #expect(plan.contains { $0.contains("USING INDEX item_live_recent") }, "plan: \(plan)")
        // Documents the expression-sort caveat above; not a claim it's fixed.
        #expect(plan.contains { $0.contains("TEMP B-TREE") && $0.contains("ORDER BY") }, "plan: \(plan)")
    }

    /// `browseHistory`'s filters-only branch (a `kind:` search with no free
    /// text): `WHERE deletedAt IS NULL AND isSecret = 0 AND kind = ? ORDER BY
    /// lastUsedAt DESC`. Observed plan: `["SEARCH item USING INDEX
    /// item_live_kind (kind=?)"]` — `item_live_kind`'s column order (kind,
    /// then lastUsedAt DESC) satisfies both the filter and the sort in one
    /// indexed search, no scan or temp sort at all.
    @Test func browseHistoryKindFilterQueryPlan() throws {
        let queue = try makeQueue()
        for index in 0 ..< 20 {
            try self.seed(queue, id: "item-\(index)", kind: index.isMultiple(of: 2) ? "text" : "image")
        }

        let sql = """
        SELECT item.* FROM item WHERE item.deletedAt IS NULL AND item.isSecret = 0 AND item.kind = ? \
        ORDER BY item.lastUsedAt DESC LIMIT ?
        """
        let plan = try self.plan(queue, sql: sql, arguments: ["text", 200])

        #expect(plan.contains { $0.contains("USING INDEX item_live_kind") }, "plan: \(plan)")
        // No bare table scan and no separate sort step.
        #expect(!plan.contains { $0 == "SCAN item" }, "plan: \(plan)")
        #expect(!plan.contains { $0.contains("TEMP B-TREE") }, "plan: \(plan)")
    }

    /// `purge`'s victim-selection query: a tombstone branch
    /// (`deletedAt IS NOT NULL`, unioned with the live-overflow branch
    /// (`deletedAt IS NULL AND isPinned = 0`, frecency-ordered `LIMIT`).
    /// Observed plan: `["COMPOUND QUERY", "LEFT-MOST SUBQUERY", "SCAN item",
    /// "UNION USING TEMP B-TREE", "SCAN item USING INDEX item_live_recent",
    /// "LIST SUBQUERY 2", "SCAN item USING INDEX item_live_recent", "USE TEMP
    /// B-TREE FOR LAST TERM OF ORDER BY"]`.
    ///
    /// The tombstone branch (`SCAN item`, bare) stays a full table scan —
    /// `item_live_recent`/`item_live_kind` are both `WHERE deletedAt IS
    /// NULL` partial indexes, the opposite condition, so they can't cover
    /// "find the tombstones" at all. That's inherent to a live-only partial
    /// index, not something this migration was meant to fix (tombstones are
    /// a small, transient fraction of the table between purges). The live
    /// branch's two scans (the outer `NOT IN` filter and the inner `LIMIT`
    /// subquery) do use `item_live_recent` — same expression-sort caveat as
    /// `recentQueryPlan` for the final ORDER BY.
    @Test func purgeVictimSelectionQueryPlan() throws {
        let queue = try makeQueue()
        for index in 0 ..< 20 {
            try self.seed(queue, id: "item-\(index)")
        }

        let sql = """
        SELECT id FROM item WHERE deletedAt IS NOT NULL
        UNION
        SELECT id FROM item
        WHERE deletedAt IS NULL AND isPinned = 0 AND id NOT IN (
            SELECT id FROM item
            WHERE deletedAt IS NULL AND isPinned = 0
            ORDER BY \(ClipStore.frecencyOrderSQL)
            LIMIT ?
        )
        """
        let plan = try self.plan(queue, sql: sql, arguments: [5])

        let liveRecentScans = plan.count(where: { $0.contains("USING INDEX item_live_recent") })
        #expect(liveRecentScans >= 2, "plan: \(plan)")
        // The tombstone branch's bare table scan is documented above as
        // inherent, not asserted away.
        #expect(plan.contains { $0 == "SCAN item" }, "plan: \(plan)")
    }
}
