import Foundation
@testable import OverboardCore
import Testing

struct UpcomingEventFormatterTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// 2026-09-13 10:00:00 UTC.
    private static let now = Self.calendar.date(from: DateComponents(
        year: 2026, month: 9, day: 13, hour: 10, minute: 0
    ))!

    private func event(startOffset: TimeInterval, duration: TimeInterval = 1800) -> CalendarEvent {
        CalendarEvent(
            eventIdentifier: "evt1",
            title: "Standup",
            start: Self.now.addingTimeInterval(startOffset),
            end: Self.now.addingTimeInterval(startOffset + duration)
        )
    }

    @Test func inProgressEventIsNow() {
        let event = self.event(startOffset: -600, duration: 1800)
        #expect(UpcomingEventFormatter.relative(to: event, now: Self.now) == "now")
    }

    @Test func underAMinuteAway() {
        let event = self.event(startOffset: 30)
        #expect(UpcomingEventFormatter.relative(to: event, now: Self.now) == "in <1m")
    }

    @Test func minutesAway() {
        let event = self.event(startOffset: 12 * 60)
        #expect(UpcomingEventFormatter.relative(to: event, now: Self.now) == "in 12m")
    }

    @Test func hoursAndMinutesAway() {
        let event = self.event(startOffset: 65 * 60)
        #expect(UpcomingEventFormatter.relative(to: event, now: Self.now) == "in 1h 05m")
    }

    @Test func justUnderADayStillShowsHoursAndMinutes() {
        let event = self.event(startOffset: 20 * 3600)
        #expect(UpcomingEventFormatter.relative(to: event, now: Self.now) == "in 20h 00m")
    }

    @Test func aDayOrMoreAwayIsTomorrow() {
        let event = self.event(startOffset: 86400)
        #expect(UpcomingEventFormatter.relative(to: event, now: Self.now) == "tomorrow")

        let further = self.event(startOffset: 30 * 3600)
        #expect(UpcomingEventFormatter.relative(to: further, now: Self.now) == "tomorrow")
    }

    @Test func endedEventFallsBackToNow() {
        let event = self.event(startOffset: -3600, duration: 1800)
        #expect(UpcomingEventFormatter.relative(to: event, now: Self.now) == "now")
    }

    @Test func timeRangeUsesEnDashOnSameDay() {
        let event = self.event(startOffset: 30 * 60, duration: 30 * 60)
        #expect(UpcomingEventFormatter.timeRange(for: event, now: Self.now, calendar: Self.calendar) == "10:30–11:00")
    }

    @Test func timeRangeAddsTomorrowPrefixOnADifferentDay() {
        let event = self.event(startOffset: 20 * 3600, duration: 1800)
        let range = UpcomingEventFormatter.timeRange(for: event, now: Self.now, calendar: Self.calendar)
        #expect(range.hasPrefix("Tomorrow "))
        #expect(range.contains("–"))
    }

    @Test func subtitleCombinesRelativeAndRangeWithMiddot() {
        let event = self.event(startOffset: 12 * 60, duration: 30 * 60)
        let subtitle = UpcomingEventFormatter.subtitle(for: event, now: Self.now, calendar: Self.calendar)
        #expect(subtitle == "in 12m · 10:12–10:42")
    }
}
