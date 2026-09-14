import Foundation

/// Formats clip and card timestamps against an explicit `now`, never the
/// system clock, so callers (and their snapshot tests) are deterministic.
public enum TimestampFormatter {
    /// "5 minutes ago", "yesterday", "now" — or "5 min. ago" with
    /// `unitsStyle: .abbreviated` where a clipboard card has ~170pt to share
    /// with its metadata. `now` is explicit (never `.now` inside) so cards,
    /// rows, and snapshots are deterministic.
    public static func relative(
        _ date: Date,
        now: Date,
        unitsStyle: Date.RelativeFormatStyle.UnitsStyle = .wide
    ) -> String {
        // Clock drift can put a fresh capture a few seconds in the future;
        // "in 4 seconds" on a clipboard card is wrong, "now" is right.
        let clamped = min(date, now)
        // `AnchoredRelativeFormatStyle` reads as "format `self` (the current
        // instant) relative to `anchor` (the past instant)" — the receiver is
        // the *later* date, not the one being described. Swapping them silently
        // flips every result ("5 minutes ago" becomes "in 5 minutes").
        return now.formatted(
            Date.AnchoredRelativeFormatStyle(anchor: clamped, presentation: .named, unitsStyle: unitsStyle)
        )
    }

    /// "Nov 14, 2023 at 10:13 PM" — tooltip, accessibility, preview metadata.
    public static func absolute(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
