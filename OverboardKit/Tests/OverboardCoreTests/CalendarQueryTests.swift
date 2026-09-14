import Foundation
@testable import OverboardCore
import Testing

struct CalendarQueryTests {
    @Test(arguments: ["cal", "calendar", "today", "tomorrow", "meetings", "meeting", "events", "CAL "])
    func triggerWordsMatch(_ query: String) {
        #expect(CalendarQuery.matches(query))
    }

    @Test(arguments: ["cale", "tod", "tom", "meet", "even"])
    func prefixesOfAtLeastThreeMatch(_ query: String) {
        #expect(CalendarQuery.matches(query))
    }

    @Test func calcDoesNotMatch() {
        #expect(!CalendarQuery.matches("calc"))
    }

    @Test(arguments: ["to", "me", "ev", ""])
    func shortNonMatchesAreRejected(_ query: String) {
        #expect(!CalendarQuery.matches(query))
    }

    @Test func unrelatedQueryDoesNotMatch() {
        #expect(!CalendarQuery.matches("swift grdb"))
    }

    @Test func tomorrowNarrowsTheWindow() {
        #expect(CalendarQuery.window(for: "tomorrow") == .tomorrowOnly)
        #expect(CalendarQuery.window(for: "tom") == .tomorrowOnly)
    }

    @Test(arguments: ["cal", "calendar", "today", "meetings", "events"])
    func everyOtherTriggerKeepsTheDefaultWindow(_ query: String) {
        #expect(CalendarQuery.window(for: query) == .todayAndTomorrow)
    }
}
