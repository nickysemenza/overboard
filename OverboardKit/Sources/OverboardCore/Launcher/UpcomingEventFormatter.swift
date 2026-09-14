import Foundation

/// Formats the calendar row's subtitle: a relative lead-time ("in 12m") and a
/// clock time range ("10:30 – 11:00"). Every function takes an explicit `now`
/// (and, where it matters, `calendar`) so results are deterministic in tests
/// — nothing here reads the system clock or the user's calendar itself.
public enum UpcomingEventFormatter {
    /// Buckets how far away `event.start` is from `now` by elapsed duration:
    /// "now" while the event is in progress, "in <1m" / "in Nm" under an hour,
    /// "in NhMMm" under a day, "tomorrow" at a day or more. Deliberately a
    /// duration check rather than a calendar-day crossing — the upcoming-events
    /// window this feeds is already capped to today + tomorrow.
    public static func relative(to event: CalendarEvent, now: Date) -> String {
        if event.start <= now, now < event.end {
            return "now"
        }
        let interval = event.start.timeIntervalSince(now)
        guard interval > 0 else { return "now" }
        if interval < 60 {
            return "in <1m"
        }
        if interval < 3600 {
            return "in \(Int(interval / 60))m"
        }
        if interval < 86400 {
            let minutes = Int(interval / 60)
            return String(format: "in %dh %02dm", minutes / 60, minutes % 60)
        }
        return "tomorrow"
    }

    /// "10:30 – 11:00" in the calendar's locale (a 12-hour clock reads
    /// "10:30 – 11:00 AM" — `DateIntervalFormatter` collapses the shared
    /// AM/PM); prefixed "Tomorrow " when `event.start`
    /// isn't the same day as `now`.
    public static func timeRange(for event: CalendarEvent, now: Date,
                                 calendar: Calendar = .autoupdatingCurrent) -> String
    {
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .autoupdatingCurrent
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let range = formatter.string(from: event.start, to: event.end)
        return calendar.isDate(event.start, inSameDayAs: now) ? range : "Tomorrow \(range)"
    }

    /// The row's whole subtitle: "\(relative) · \(timeRange)".
    public static func subtitle(for event: CalendarEvent, now: Date,
                                calendar: Calendar = .autoupdatingCurrent) -> String
    {
        "\(self.relative(to: event, now: now)) · \(self.timeRange(for: event, now: now, calendar: calendar))"
    }

    /// The preview pane's multi-line body: title, a full date + time range,
    /// the source calendar, location, join link, and notes — whichever of the
    /// optional fields are actually present, in that order.
    public static func preview(for event: CalendarEvent, now: Date,
                               calendar: Calendar = .autoupdatingCurrent) -> String
    {
        var lines = [event.title, self.fullDateAndRange(for: event, now: now, calendar: calendar)]
        if let calendarTitle = event.calendarTitle, !calendarTitle.isEmpty {
            lines.append(calendarTitle)
        }
        if let location = event.location, !location.isEmpty {
            lines.append(location)
        }
        if let link = event.meetingLink {
            lines.append(link.url.absoluteString)
        }
        if let notes = event.notes, !notes.isEmpty {
            lines.append(notes)
        }
        return lines.joined(separator: "\n")
    }

    /// "Tuesday, September 15, 2026 at 10:30 – 11:00 AM" — the preview's full
    /// date, unlike `timeRange`'s bare clock time.
    private static func fullDateAndRange(for event: CalendarEvent, now _: Date, calendar: Calendar) -> String {
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .autoupdatingCurrent
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter.string(from: event.start, to: event.end)
    }
}
