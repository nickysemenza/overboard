import Foundation
import GRDB

/// Live-item captures per local calendar day, per kind, for the History tab
/// timeline. Every day in the window is present, zero-filled, oldest first.
public struct DailyActivity: Sendable {
    public struct Day: Sendable, Identifiable {
        /// Start of this day in the `calendar` `dailyActivity` was called with.
        public let date: Date
        /// Only kinds captured on this day are present; a missing kind means 0.
        public let counts: [ItemKind: Int]
        public var total: Int {
            self.counts.values.reduce(0, +)
        }

        public var id: Date {
            self.date
        }

        public init(date: Date, counts: [ItemKind: Int]) {
            self.date = date
            self.counts = counts
        }
    }

    /// Oldest first, one entry per day in the window.
    public let days: [Day]
    public let total: Int

    public init(days: [Day], total: Int) {
        self.days = days
        self.total = total
    }
}

public extension ClipStore {
    /// Buckets live (non-deleted) items into calendar days for the History
    /// tab's activity timeline. The window is the `days` calendar days ending
    /// at `calendar.startOfDay(for: now)`, inclusive; every day in it is
    /// present even if nothing was captured that day.
    ///
    /// Bucketing happens in Swift rather than via SQLite's `'localtime'`
    /// modifier so `calendar` is actually honored (a caller can pass a fixed
    /// UTC calendar in tests) and so the C library's timezone database never
    /// enters the picture. The window is bounded by `historyLimit` (5,000)
    /// live rows at most, so pulling `createdAt`/`kind` for it and bucketing
    /// in-process is cheap.
    func dailyActivity(
        days: Int = 30, now: Date = Date(), calendar: Calendar = .current
    ) async throws -> DailyActivity {
        let todayStart = calendar.startOfDay(for: now)
        guard days > 0, let windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart)
        else {
            return DailyActivity(days: [], total: 0)
        }

        // GRDB's `Row` isn't `Sendable`, so the closure below reduces each row
        // to this plain `Sendable` pair before it crosses back out of
        // `dbWriter.read` — returning `[Row]` directly would make the
        // compiler fall back to the synchronous `read` overload instead of
        // suspending, since the async one requires a `Sendable` result.
        struct CapturedAtKind: Sendable {
            let createdAt: Date
            let kind: String
        }

        let rows: [CapturedAtKind] = try await self.dbWriter.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT createdAt, kind FROM item WHERE deletedAt IS NULL AND createdAt >= ?",
                arguments: [windowStart]
            ).compactMap { row in
                guard let createdAt: Date = row["createdAt"], let kind: String = row["kind"] else { return nil }
                return CapturedAtKind(createdAt: createdAt, kind: kind)
            }
        }

        var dayDates: [Date] = []
        var buckets: [Date: [ItemKind: Int]] = [:]
        var cursor = windowStart
        for _ in 0 ..< days {
            dayDates.append(cursor)
            buckets[cursor] = [:]
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
        }

        var total = 0
        for row in rows {
            guard let kind = ItemKind(rawValue: row.kind) else { continue }
            let dayStart = calendar.startOfDay(for: row.createdAt)
            guard buckets[dayStart] != nil else { continue }
            buckets[dayStart, default: [:]][kind, default: 0] += 1
            total += 1
        }

        let orderedDays = dayDates.map { date in
            DailyActivity.Day(date: date, counts: buckets[date] ?? [:])
        }
        return DailyActivity(days: orderedDays, total: total)
    }
}
