import Foundation

/// Pure builder for the AppleScript that reads a browser's front-tab URL and
/// title, used by back-to-source provenance. Kept here (no AppKit, no
/// NSAppleScript) so the dialect map and script shape are unit-testable; the
/// platform layer in OverboardMac owns the actual Apple Event round-trip.
public enum BrowserScript {
    /// The two AppleScript dialects that expose a front tab. Safari and
    /// Chromium-family browsers phrase "the current page" differently.
    public enum Dialect: Sendable, Equatable {
        case safari
        case chromium
    }

    /// Maps a source bundle identifier to the browser dialect that can script
    /// it, or nil for apps that can't (or that we won't) ask for a URL —
    /// including Firefox, which has no AppleScript URL support.
    public static func dialect(forBundleID id: String) -> Dialect? {
        switch id {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            .safari
        case "com.google.Chrome",
             "com.google.Chrome.canary",
             "com.brave.Browser",
             "com.microsoft.edgemac",
             "com.vivaldi.Vivaldi",
             "company.thebrowser.Browser", // Arc
             "org.chromium.Chromium":
            .chromium
        default:
            nil
        }
    }

    /// AppleScript source returning "URL<tab>title" for the browser's front
    /// tab, or "" when the browser has no windows (rather than erroring). The
    /// caller resolves the app by bundle id so the exact browser is targeted
    /// even when several share a dialect.
    public static func source(for dialect: Dialect, bundleID: String) -> String {
        switch dialect {
        case .safari:
            """
            tell application id "\(bundleID)"
                try
                    if (count of documents) is 0 then return ""
                    return (URL of front document) & tab & (name of front document)
                on error
                    return ""
                end try
            end tell
            """
        case .chromium:
            """
            tell application id "\(bundleID)"
                try
                    if (count of windows) is 0 then return ""
                    return (URL of active tab of front window) & tab \
            & (title of active tab of front window)
                on error
                    return ""
                end try
            end tell
            """
        }
    }
}
