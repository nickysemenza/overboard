import OverboardCore
@testable import OverboardUI
import SnapshotTesting
import SwiftUI
import Testing

/// The three History tab charts, light and dark, fed literal `LibraryStats`
/// and `DailyActivity` values rather than a live store so the bars and
/// colors are fully deterministic. Each host paints `.background` under the
/// chart: in the app the Form's section row does that, and without it the
/// dark-appearance axis ink lands on the bitmap's white and vanishes.
@MainActor
struct LibraryChartsSnapshotTests {
    // MARK: - Kind breakdown

    private static let kindEntries: [LibraryStats.KindCount] = [
        .init(kind: .text, count: 120),
        .init(kind: .link, count: 45),
        .init(kind: .image, count: 20),
        .init(kind: .file, count: 10),
        .init(kind: .color, count: 3),
    ]

    private func kindHost(dark: Bool = false) -> NSImage {
        snapshotImage(
            KindBreakdownChart(byKind: Self.kindEntries).padding(8).background(.background),
            width: 480,
            height: CGFloat(Self.kindEntries.count) * 22 + 16,
            dark: dark
        )
    }

    @Test func kindBreakdown() {
        assertSnapshot(of: self.kindHost(), as: snapshotImageStrategy)
    }

    @Test func kindBreakdownDark() {
        assertSnapshot(of: self.kindHost(dark: true), as: snapshotImageStrategy)
    }

    // MARK: - Source breakdown

    private static let sourceEntries: [LibraryStats.SourceCount] = [
        .init(app: "Safari", count: 64),
        .init(app: "Xcode", count: 31),
        .init(app: "Messages", count: 12),
    ]

    private func sourceHost(dark: Bool = false) -> NSImage {
        snapshotImage(
            SourceBreakdownChart(bySource: Self.sourceEntries).padding(8).background(.background),
            width: 480,
            height: CGFloat(Self.sourceEntries.count) * 22 + 16,
            dark: dark
        )
    }

    @Test func sourceBreakdown() {
        assertSnapshot(of: self.sourceHost(), as: snapshotImageStrategy)
    }

    @Test func sourceBreakdownDark() {
        assertSnapshot(of: self.sourceHost(dark: true), as: snapshotImageStrategy)
    }

    // MARK: - Activity timeline

    /// A fixed instant (not `Date()`) so the x-axis month/day labels the
    /// chart formats through the default locale never drift between a
    /// recording run and a later assertion run.
    private static let fixedNow = Date(timeIntervalSince1970: 1_757_721_600)

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static let activity: DailyActivity = {
        let calendar = Self.utc
        let todayStart = calendar.startOfDay(for: Self.fixedNow)
        let days: [DailyActivity.Day] = (0 ..< 30).map { offset in
            let date = calendar.date(byAdding: .day, value: -(29 - offset), to: todayStart) ?? todayStart
            let counts: [ItemKind: Int] = offset.isMultiple(of: 4)
                ? [:]
                : [.text: 3 + offset % 5, .link: offset % 3]
            return DailyActivity.Day(date: date, counts: counts)
        }
        return DailyActivity(days: days, total: days.reduce(0) { $0 + $1.total })
    }()

    private func timelineHost(dark: Bool = false) -> NSImage {
        snapshotImage(
            ActivityTimelineChart(activity: Self.activity).padding(8).background(.background),
            width: 480,
            height: 140 + 16,
            dark: dark
        )
    }

    @Test func activityTimeline() {
        assertSnapshot(of: self.timelineHost(), as: snapshotImageStrategy)
    }

    @Test func activityTimelineDark() {
        assertSnapshot(of: self.timelineHost(dark: true), as: snapshotImageStrategy)
    }

    // MARK: - Activity timeline — empty

    private func emptyTimelineHost(dark: Bool = false) -> NSImage {
        let calendar = Self.utc
        let todayStart = calendar.startOfDay(for: Self.fixedNow)
        let days: [DailyActivity.Day] = (0 ..< 30).map { offset in
            let date = calendar.date(byAdding: .day, value: -(29 - offset), to: todayStart) ?? todayStart
            return DailyActivity.Day(date: date, counts: [:])
        }
        let activity = DailyActivity(days: days, total: 0)
        return snapshotImage(
            ActivityTimelineChart(activity: activity).padding(8).background(.background),
            width: 480,
            // The empty placeholder's default label style wants more room
            // than the chart's own 140pt — see the `minHeight` comment on
            // `ActivityTimelineChart`.
            height: 220,
            dark: dark
        )
    }

    @Test func activityTimelineEmpty() {
        assertSnapshot(of: self.emptyTimelineHost(), as: snapshotImageStrategy)
    }
}
