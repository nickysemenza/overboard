import Foundation
@testable import OverboardCore
import Testing

struct TimestampFormatterTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func fiveMinutesAgo() {
        let date = Self.now.addingTimeInterval(-300)
        #expect(TimestampFormatter.relative(date, now: Self.now) == "5 minutes ago")
    }

    @Test func abbreviatedUnitsForCards() {
        let date = Self.now.addingTimeInterval(-300)
        #expect(TimestampFormatter.relative(date, now: Self.now, unitsStyle: .abbreviated) == "5 min. ago")
    }

    @Test func yesterday() {
        let date = Self.now.addingTimeInterval(-86400)
        #expect(TimestampFormatter.relative(date, now: Self.now) == "yesterday")
    }

    @Test func futureClampsToNow() {
        let date = Self.now.addingTimeInterval(30)
        #expect(TimestampFormatter.relative(date, now: Self.now) == "now")
    }

    @Test func exactlyNowIsNow() {
        #expect(TimestampFormatter.relative(Self.now, now: Self.now) == "now")
    }
}
