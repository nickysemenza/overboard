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

    /// One browser Overboard knows how to script, with the name to show a user.
    public struct Browser: Sendable, Equatable {
        public let name: String
        public let bundleID: String
        public let dialect: Dialect
    }

    /// Every browser we can ask for a front-tab URL, newest-first within each
    /// family. The single source of truth for both the provenance lookup below
    /// and the per-app Automation rows in Settings → Permissions, so the two
    /// can't list different browsers. Firefox is absent deliberately: it has no
    /// AppleScript URL support.
    public static let scriptableBrowsers: [Browser] = [
        Browser(name: "Safari", bundleID: "com.apple.Safari", dialect: .safari),
        Browser(name: "Safari Technology Preview", bundleID: "com.apple.SafariTechnologyPreview", dialect: .safari),
        Browser(name: "Chrome", bundleID: "com.google.Chrome", dialect: .chromium),
        Browser(name: "Chrome Canary", bundleID: "com.google.Chrome.canary", dialect: .chromium),
        Browser(name: "Arc", bundleID: "company.thebrowser.Browser", dialect: .chromium),
        Browser(name: "Brave", bundleID: "com.brave.Browser", dialect: .chromium),
        Browser(name: "Edge", bundleID: "com.microsoft.edgemac", dialect: .chromium),
        Browser(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", dialect: .chromium),
        Browser(name: "Chromium", bundleID: "org.chromium.Chromium", dialect: .chromium),
    ]

    /// Maps a source bundle identifier to the browser dialect that can script
    /// it, or nil for apps that can't (or that we won't) ask for a URL.
    public static func dialect(forBundleID id: String) -> Dialect? {
        self.scriptableBrowsers.first { $0.bundleID == id }?.dialect
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
