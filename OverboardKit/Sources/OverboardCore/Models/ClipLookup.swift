import Foundation

/// The selection rules the App Intents (Shortcuts, Siri, Spotlight actions)
/// apply to a listing from `ClipStore`.
///
/// The intents themselves are instantiated by the system and can't be built in
/// a test, so the parts worth testing — which item a listing yields, and what
/// text is handed back for it — live here as pure functions over rows the
/// intent already fetched.
public enum ClipLookup {
    /// How many rows `CopyLatestClipIntent` asks for. A few more than the one
    /// it needs, so a run of secrets at the top doesn't starve it.
    public static let recentScanLimit = 20
    /// How many search hits `SearchClipboardIntent` asks for, for the same
    /// reason: a secret ranked above the true best match must not block it.
    public static let searchScanLimit = 10

    /// The first item an intent may hand to Shortcuts/Siri: secrets are always
    /// skipped, so a detected credential never leaves the app this way.
    public static func firstUsable(in items: [ClipItem]) -> ClipItem? {
        items.first { !$0.isSecret }
    }

    /// The string value an intent returns for an item. `plainText` is the
    /// stored payload (absent for image-only clips); `fallback` is whatever the
    /// caller would rather return than nothing — the truncated preview for
    /// search, nil for the copy intents, where an empty string is the honest
    /// answer for "there was no text to copy".
    public static func resultText(plainText: String?, fallback: String? = nil) -> String {
        plainText ?? fallback ?? ""
    }
}
