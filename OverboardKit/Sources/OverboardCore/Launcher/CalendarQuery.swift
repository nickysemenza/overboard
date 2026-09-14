import Foundation

/// Recognizes the launcher queries that should surface upcoming calendar
/// events, and how far ahead each one should look.
public enum CalendarQuery {
    /// today+tomorrow (the default span every trigger word gets) or just
    /// tomorrow (only the `tomorrow` trigger itself narrows to this).
    public enum Window: Sendable, Equatable {
        case todayAndTomorrow, tomorrowOnly
    }

    /// Words that, typed in full or as a prefix of at least 3 characters,
    /// trigger the upcoming-events list. Exact-or-prefix (not substring) so
    /// "calc" never matches "calendar" — "calc" would need to be a prefix of
    /// "calendar", and it isn't ("cal" vs "calc" diverge at the 4th letter).
    private static let triggers = ["cal", "calendar", "today", "tomorrow", "meetings", "meeting", "events"]

    public static func matches(_ query: String) -> Bool {
        let folded = Self.fold(query)
        guard !folded.isEmpty else { return false }
        return Self.triggers.contains { trigger in
            trigger == folded || (folded.count >= 3 && trigger.hasPrefix(folded))
        }
    }

    /// `.tomorrowOnly` only when the query is (a prefix of, or exactly)
    /// "tomorrow" itself; every other trigger — including "today" — keeps the
    /// default two-day span.
    public static func window(for query: String) -> Window {
        let folded = Self.fold(query)
        guard folded.count >= 3, "tomorrow".hasPrefix(folded) else {
            return .todayAndTomorrow
        }
        return .tomorrowOnly
    }

    private static func fold(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
