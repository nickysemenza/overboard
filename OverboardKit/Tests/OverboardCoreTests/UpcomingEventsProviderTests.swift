import Foundation
@testable import OverboardCore
import Testing

struct UpcomingEventsProviderTests {
    private static let now = Date(timeIntervalSince1970: 1_757_757_600) // 2025-09-13 10:00:00 UTC

    // The provider windows against `Calendar.autoupdatingCurrent` (it isn't
    // injectable), so day-boundary tests derive their offsets from the same
    // calendar's `startOfDay` instead of fixed hour counts — those would be
    // one calendar day off depending on the host's time zone.
    private static let calendar = Calendar.autoupdatingCurrent
    private static let todayStart = Self.calendar.startOfDay(for: Self.now)
    private static let tomorrowStart = Self.calendar.date(byAdding: .day, value: 1, to: Self.todayStart)!
    private static let dayAfterStart = Self.calendar.date(byAdding: .day, value: 2, to: Self.todayStart)!

    private func event(id: String, start: Date, duration: TimeInterval = 1800) -> CalendarEvent {
        CalendarEvent(eventIdentifier: id, title: id, start: start, end: start.addingTimeInterval(duration))
    }

    private func event(id: String, startOffset: TimeInterval, duration: TimeInterval = 1800) -> CalendarEvent {
        CalendarEvent(
            eventIdentifier: id,
            title: id,
            start: Self.now.addingTimeInterval(startOffset),
            end: Self.now.addingTimeInterval(startOffset + duration)
        )
    }

    private func provider(events: [CalendarEvent], isAuthorized: Bool = true,
                          limit: Int = 8) -> UpcomingEventsProvider
    {
        UpcomingEventsProvider(events: { events }, isAuthorized: { isAuthorized }, now: { Self.now }, limit: limit)
    }

    @Test func nonTriggerQueryReturnsNothing() async {
        let provider = self.provider(events: [self.event(id: "e1", startOffset: 600)])
        let results = await provider.results(for: "swift grdb")
        #expect(results.isEmpty)
    }

    @Test func unauthorizedShowsSettingsRow() async {
        let provider = self.provider(events: [self.event(id: "e1", startOffset: 600)], isAuthorized: false)
        let results = await provider.results(for: "cal")
        #expect(results == [.command(.settings, subtitle: "Grant Calendar access in Permissions to see events")])
    }

    @Test func sortedByStartAndCappedAtLimit() async {
        let events = (0 ..< 12).map { self.event(id: "e\($0)", startOffset: TimeInterval(3600 * (12 - $0))) }
        let provider = self.provider(events: events, limit: 8)
        let results = await provider.results(for: "cal")
        #expect(results.count == 8)
        let ids = results.compactMap { result -> String? in
            if case let .calendarEvent(event) = result {
                event.eventIdentifier
            } else {
                nil
            }
        }
        #expect(ids == ["e11", "e10", "e9", "e8", "e7", "e6", "e5", "e4"])
    }

    @Test func dropsEventsThatHaveEnded() async {
        let ended = self.event(id: "ended", startOffset: -7200, duration: 1800)
        let inProgress = self.event(id: "in-progress", startOffset: -600, duration: 1800)
        let upcoming = self.event(id: "upcoming", startOffset: 600)
        let provider = self.provider(events: [ended, inProgress, upcoming])
        let results = await provider.results(for: "cal")
        let ids = results.compactMap { result -> String? in
            if case let .calendarEvent(event) = result {
                event.eventIdentifier
            } else {
                nil
            }
        }
        #expect(ids == ["in-progress", "upcoming"])
    }

    @Test func tomorrowQueryExcludesToday() async {
        let today = self.event(id: "today", start: Self.now.addingTimeInterval(60))
        let tomorrow = self.event(id: "tomorrow-evt", start: Self.tomorrowStart.addingTimeInterval(3600))
        let provider = self.provider(events: [today, tomorrow])
        let results = await provider.results(for: "tomorrow")
        let ids = results.compactMap { result -> String? in
            if case let .calendarEvent(event) = result {
                event.eventIdentifier
            } else {
                nil
            }
        }
        #expect(ids == ["tomorrow-evt"])
    }

    @Test func defaultWindowIncludesTodayAndTomorrowButNotTheDayAfter() async {
        let today = self.event(id: "today", start: Self.now.addingTimeInterval(60))
        let tomorrow = self.event(id: "tomorrow-evt", start: Self.tomorrowStart.addingTimeInterval(3600))
        let dayAfter = self.event(id: "day-after", start: Self.dayAfterStart.addingTimeInterval(3600))
        let provider = self.provider(events: [today, tomorrow, dayAfter])
        let results = await provider.results(for: "cal")
        let ids = results.compactMap { result -> String? in
            if case let .calendarEvent(event) = result {
                event.eventIdentifier
            } else {
                nil
            }
        }
        #expect(ids == ["today", "tomorrow-evt"])
    }
}
