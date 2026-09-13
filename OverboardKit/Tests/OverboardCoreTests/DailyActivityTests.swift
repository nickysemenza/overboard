import Foundation
@testable import OverboardCore
import Testing

struct DailyActivityTests {
    /// Fixed UTC calendar so bucketing never depends on the host's wall-clock
    /// timezone or the moment the suite happens to run.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private var now: Date {
        // Noon UTC, safely mid-day so `startOfDay` never crosses a boundary.
        self.utc.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 12))!
    }

    private func makeStore() throws -> ClipStore {
        let queue = try OverboardDatabase.openInMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-activity-\(UUID().uuidString)", isDirectory: true)
        return try ClipStore(dbWriter: queue, blobs: BlobStore(directory: dir))
    }

    private func textSnapshot(_ text: String, capturedAt: Date) -> PasteboardSnapshot {
        PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data(text.utf8))],
            sourceBundleID: "com.example.app",
            sourceAppName: "Example",
            capturedAt: capturedAt
        )
    }

    private func daysAgo(_ count: Int) -> Date {
        self.utc.date(byAdding: .day, value: -count, to: self.now)!
    }

    @Test func bucketsIntoThirtyZeroFilledDaysOldestFirst() async throws {
        let store = try makeStore()
        try await store.ingest(self.textSnapshot("today text", capturedAt: self.now))
        try await store.ingest(self.textSnapshot("https://example.com/docs", capturedAt: self.daysAgo(1)))
        try await store.ingest(self.textSnapshot("five days ago", capturedAt: self.daysAgo(5)))
        // Outside the 30-day window — must be excluded.
        try await store.ingest(self.textSnapshot("forty days ago", capturedAt: self.daysAgo(40)))

        let activity = try await store.dailyActivity(now: self.now, calendar: self.utc)

        #expect(activity.days.count == 30)
        #expect(activity.days.first?.date == self.utc.startOfDay(for: self.daysAgo(29)))
        #expect(activity.days.last?.date == self.utc.startOfDay(for: self.now))
        #expect(activity.total == 3)

        // Gaps are zero-filled.
        let nonEmptyDays = activity.days.filter { $0.total > 0 }
        #expect(nonEmptyDays.count == 3)

        // Per-kind counts land on the right day.
        let today = activity.days.last
        #expect(today?.counts[.text] == 1)
        #expect(today?.counts[.link] == nil)

        let oneDayAgo = activity.days[activity.days.count - 2]
        #expect(oneDayAgo.counts[.link] == 1)
        #expect(oneDayAgo.counts[.text] == nil)

        let fiveDaysAgo = activity.days[activity.days.count - 6]
        #expect(fiveDaysAgo.counts[.text] == 1)
    }

    @Test func deletedItemsAreExcluded() async throws {
        let store = try makeStore()
        let item = try await store.ingest(self.textSnapshot("delete me", capturedAt: self.now))
        try await store.delete(id: #require(item).id)

        let activity = try await store.dailyActivity(now: self.now, calendar: self.utc)
        #expect(activity.total == 0)
        #expect(activity.days.allSatisfy { $0.total == 0 })
    }

    @Test func respectsCustomWindowSize() async throws {
        let store = try makeStore()
        try await store.ingest(self.textSnapshot("today text", capturedAt: self.now))

        let activity = try await store.dailyActivity(days: 7, now: self.now, calendar: self.utc)
        #expect(activity.days.count == 7)
        #expect(activity.total == 1)
    }
}
