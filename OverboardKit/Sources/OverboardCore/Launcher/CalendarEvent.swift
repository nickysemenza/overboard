import Foundation

/// One calendar event as surfaced by OverboardMac's `CalendarSource`. Core
/// holds only value data — `EKEvent` isn't `Sendable`, so `CalendarSource`
/// converts eagerly, off the main actor, before handing events back.
public struct CalendarEvent: Sendable, Equatable, Identifiable {
    public let eventIdentifier: String
    public let title: String
    public let start: Date
    public let end: Date
    public let location: String?
    public let notes: String?
    public let url: URL?
    public let calendarTitle: String?
    public let isAllDay: Bool

    public init(
        eventIdentifier: String,
        title: String,
        start: Date,
        end: Date,
        location: String? = nil,
        notes: String? = nil,
        url: URL? = nil,
        calendarTitle: String? = nil,
        isAllDay: Bool = false
    ) {
        self.eventIdentifier = eventIdentifier
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.notes = notes
        self.url = url
        self.calendarTitle = calendarTitle
        self.isAllDay = isAllDay
    }

    /// EventKit reuses one `eventIdentifier` across every occurrence of a
    /// repeating event, so the start time disambiguates instances for row
    /// identity and de-duping.
    public var id: String {
        "\(self.eventIdentifier)@\(self.start.timeIntervalSince1970)"
    }

    /// The event's join link, detected from its url/location/notes fields —
    /// see `MeetingLink.detect(url:location:notes:)`.
    public var meetingLink: MeetingLink? {
        MeetingLink.detect(url: self.url, location: self.location, notes: self.notes)
    }
}
