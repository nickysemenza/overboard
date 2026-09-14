import Foundation

/// Formats the calendar row's subtitle: a relative lead-time ("in 12m") and a
/// clock time range ("10:30–11:00"). Every function takes an explicit `now`
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

    /// "10:30–11:00" (en dash, always 24-hour so the row stays terse
    /// regardless of the user's clock-format preference); prefixed
    /// "Tomorrow " when `event.start` isn't the same day as `now`.
    public static func timeRange(for event: CalendarEvent, now: Date,
                                 calendar: Calendar = .autoupdatingCurrent) -> String
    {
        let formatter = Self.timeFormatter(timeZone: calendar.timeZone)
        let range = "\(formatter.string(from: event.start))–\(formatter.string(from: event.end))"
        return calendar.isDate(event.start, inSameDayAs: now) ? range : "Tomorrow \(range)"
    }

    /// The row's whole subtitle: "\(relative) · \(timeRange)".
    public static func subtitle(for event: CalendarEvent, now: Date,
                                calendar: Calendar = .autoupdatingCurrent) -> String
    {
        "\(self.relative(to: event, now: now)) · \(self.timeRange(for: event, now: now, calendar: calendar))"
    }

    /// `en_US_POSIX` pins the "HH:mm" pattern to always mean 24-hour time —
    /// some locales otherwise reinterpret literal pattern letters.
    private static func timeFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter
    }
}
