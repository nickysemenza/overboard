// Re-exported so the app target and OverboardUI reach Defaults[...] through
// their existing OverboardMac import without a pbxproj package reference.
@_exported import Defaults
import Foundation
import OverboardCore

public extension Defaults.Keys {
    // Raw key strings predate the Defaults migration — keep them byte-identical
    // so existing users' stored values survive.
    static let historyLimit = Key<Int>("historyLimit", default: 1000)
    static let restoreClipboard = Key<Bool>("restoreClipboardAfterPaste", default: true)
    static let excludedBundleIDs = Key<String>(
        "excludedBundleIDs",
        default: ClipboardMonitor.defaultExclusions.sorted().joined(separator: "\n")
    )
    static let plainTextBundleIDs = Key<String>(
        "plainTextBundleIDs",
        default: "com.apple.Terminal\ncom.googlecode.iterm2"
    )
    /// Auto-transform-on-copy rules, one "bundleID = transform" per line
    /// (transform is a ClipTransform raw value, e.g. stripTrackingParams).
    static let autoTransformRules = Key<String>("autoTransformRules", default: "")
    /// Minutes before detected secrets are hard-deleted; 0 disables expiry.
    static let secretTTLMinutes = Key<Int>("secretTTLMinutes", default: 10)
    /// Apple Intelligence features: auto-titles, categories, AI transforms.
    static let aiFeatures = Key<Bool>("aiFeatures", default: true)
    /// Poll GitHub Releases for a newer version and surface it in the menu bar.
    static let updateCheckEnabled = Key<Bool>("updateCheckEnabled", default: true)
    /// Fetch page title/description/favicon/preview for copied links over the
    /// network to render rich link cards. User-opt-in; on by default.
    static let richLinkPreviews = Key<Bool>("richLinkPreviews", default: true)
    /// Spotlight file results in the launcher bar.
    static let launcherFileResults = Key<Bool>("launcherFileResults", default: true)
    /// Clipboard-history results in the launcher bar.
    static let launcherClipResults = Key<Bool>("launcherClipResults", default: true)
    /// Snippet results in the launcher bar.
    static let launcherSnippetResults = Key<Bool>("launcherSnippetResults", default: true)
    /// System Settings pane results in the launcher bar.
    static let launcherSettingsResults = Key<Bool>("launcherSettingsResults", default: true)
    /// Spotify now-playing row pinned to the bottom of the launcher.
    static let launcherNowPlaying = Key<Bool>("launcherNowPlaying", default: true)
    /// Launcher app-search aliases, one "alias = App Name" per line.
    static let launcherAppAliases = Key<String>("launcherAppAliases", default: "")
    /// Recent launcher search queries, most-recent last; de-duped and capped.
    static let launcherSearchHistory = Key<[String]>("launcherSearchHistory", default: [])
    /// Pinned drawer searches (raw query strings), shown as chips above history.
    static let savedSearches = Key<[String]>("savedSearches", default: [])
}

/// Parsed views over the newline-list preference keys.
public enum Preferences {
    public static func currentExclusions() -> Set<String> {
        self.bundleIDSet(Defaults[.excludedBundleIDs])
    }

    /// Apps where pasted text should always be plain (terminals etc.).
    public static func currentPlainTextApps() -> Set<String> {
        self.bundleIDSet(Defaults[.plainTextBundleIDs])
    }

    /// Parsed auto-transform-on-copy rules.
    public static func currentAutoTransformRules() -> [AutoTransformRule] {
        AutoTransform.parseRules(Defaults[.autoTransformRules])
    }

    private static func bundleIDSet(_ raw: String) -> Set<String> {
        Set(
            raw.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }
}
