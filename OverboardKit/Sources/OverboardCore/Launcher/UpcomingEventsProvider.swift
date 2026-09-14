import Foundation

/// The launcher's `cal`/`calendar`/`today`/`tomorrow`/`meetings`/`events` list:
/// upcoming events over the next day or two, from OverboardMac's
/// `CalendarSource`. `events`/`isAuthorized`/`now` are injected closures (the
/// same shape as `AskAIProvider`'s `isAvailable`) so Core stays free of
/// EventKit and tests stay deterministic.
public struct UpcomingEventsProvider: LauncherProvider {
    private let events: @Sendable () -> [CalendarEvent]
    private let isAuthorized: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let limit: Int

    public init(
        events: @escaping @Sendable () -> [CalendarEvent],
        isAuthorized: @escaping @Sendable () -> Bool,
        now: @escaping @Sendable () -> Date = { .now },
        limit: Int = 8
    ) {
        self.events = events
        self.isAuthorized = isAuthorized
        self.now = now
        self.limit = limit
    }

    public var searchScopes: Set<LauncherScope> {
        [.all]
    }

    public func results(for query: String) async -> [LauncherResult] {
        guard CalendarQuery.matches(query) else { return [] }
        guard self.isAuthorized() else {
            return [.command(.settings, subtitle: "Grant Calendar access in Permissions to see events")]
        }
        let now = self.now()
        let (windowStart, windowEnd) = self.window(for: query, now: now)
        let upcoming = self.events()
            .filter { $0.end > now && $0.start >= windowStart && $0.start < windowEnd }
            .sorted { $0.start < $1.start }
            .prefix(self.limit)
        return upcoming.map { .calendarEvent($0) }
    }

    /// The `[start, end)` span to keep events from: today's midnight through
    /// two days out for the default trigger words, narrowed to just
    /// tomorrow's span when the query is "tomorrow" itself.
    private func window(for query: String, now: Date) -> (Date, Date) {
        let calendar = Calendar.autoupdatingCurrent
        let todayStart = calendar.startOfDay(for: now)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
        let dayAfterStart = calendar.date(byAdding: .day, value: 2, to: todayStart) ?? tomorrowStart
        switch CalendarQuery.window(for: query) {
        case .todayAndTomorrow:
            return (todayStart, dayAfterStart)
        case .tomorrowOnly:
            return (tomorrowStart, dayAfterStart)
        }
    }
}
