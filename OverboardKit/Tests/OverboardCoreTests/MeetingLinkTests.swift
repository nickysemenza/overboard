import Foundation
@testable import OverboardCore
import Testing

struct MeetingLinkTests {
    @Test func detectsZoomLink() {
        let link = MeetingLink.detect(in: "Join at https://zoom.us/j/1234567890")
        #expect(link?.provider == .zoom)
        #expect(link?.url.absoluteString == "https://zoom.us/j/1234567890")
    }

    @Test func detectsZoomCustomScheme() {
        let link = MeetingLink.detect(in: "zoommtg://zoom.us/join?confno=1234567890")
        #expect(link?.provider == .zoom)
    }

    @Test func detectsGoogleMeetLink() {
        let link = MeetingLink.detect(in: "https://meet.google.com/abc-defg-hij")
        #expect(link?.provider == .googleMeet)
    }

    @Test func detectsTeamsLink() {
        let link = MeetingLink.detect(in: "https://teams.microsoft.com/l/meetup-join/abc")
        #expect(link?.provider == .teams)
    }

    @Test func detectsFaceTimeCustomScheme() {
        let link = MeetingLink.detect(in: "facetime:someone@example.com")
        #expect(link?.provider == .facetime)
    }

    @Test func detectsWebexLink() {
        let link = MeetingLink.detect(in: "https://example.webex.com/meet/room")
        #expect(link?.provider == .webex)
    }

    @Test func detectsGenericHTTPSLink() {
        let link = MeetingLink.detect(in: "Dial in at https://example.com/join/123")
        #expect(link?.provider == .generic)
    }

    @Test func trailingPunctuationIsStripped() {
        // The regex path (custom schemes) greedily grabs trailing punctuation;
        // confirm it's trimmed off the resulting URL.
        let link = MeetingLink.detect(in: "(zoommtg://zoom.us/join?confno=42)")
        #expect(link?.url.absoluteString == "zoommtg://zoom.us/join?confno=42")
    }

    @Test func noLinkReturnsNil() {
        #expect(MeetingLink.detect(in: "just a plain note, nothing to see") == nil)
    }

    @Test func fieldPrecedenceKnownProviderBeatsEarlierGenericField() throws {
        let genericURL = try #require(URL(string: "https://example.com/event/123"))
        let link = MeetingLink.detect(
            url: genericURL,
            location: nil,
            notes: "Join via https://zoom.us/j/999"
        )
        #expect(link?.provider == .zoom)
    }

    @Test func fieldOrderBreaksTiesAmongGenericLinks() throws {
        let urlField = try #require(URL(string: "https://a.example.com/one"))
        let link = MeetingLink.detect(url: urlField, location: "https://b.example.com/two", notes: nil)
        #expect(link?.url == urlField)
    }

    @Test func calendarPageURLIsExcludedEvenAlone() throws {
        let calendarURL = try #require(URL(string: "https://calendar.google.com/calendar/event?eid=abc"))
        #expect(MeetingLink.detect(url: calendarURL, location: nil, notes: nil) == nil)
    }

    @Test func calendarPageURLIsSkippedInFavorOfARealLink() throws {
        let calendarURL = try #require(URL(string: "https://outlook.office.com/calendar/item/abc"))
        let link = MeetingLink.detect(url: calendarURL, location: nil, notes: "https://meet.google.com/abc-defg-hij")
        #expect(link?.provider == .googleMeet)
    }

    @Test func allFieldsNilOrEmptyReturnsNil() {
        #expect(MeetingLink.detect(url: nil, location: nil, notes: nil) == nil)
        #expect(MeetingLink.detect(url: nil, location: "", notes: "") == nil)
    }
}
