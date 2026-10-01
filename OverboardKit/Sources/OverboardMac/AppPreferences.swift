// Re-exported so the app target and OverboardUI reach Defaults[...] through
// their existing OverboardMac import without a pbxproj package reference.
@_exported import Defaults
import Foundation
import OverboardCore

public nonisolated enum AppPreferenceStorage {
    private static let demoName = "com.nickysemenza.overboard.demo.\(UUID().uuidString)"
    public nonisolated(unsafe) static let suite: UserDefaults = ProcessInfo.processInfo
        .environment["OVERBOARD_DEMO"] == "1"
        ? UserDefaults(suiteName: AppPreferenceStorage.demoName) ?? .standard : .standard

    public static func cleanUpDemo() {
        guard ProcessInfo.processInfo.environment["OVERBOARD_DEMO"] == "1" else { return }
        self.suite.removePersistentDomain(forName: self.demoName)
    }
}

public nonisolated extension Defaults.Keys {
    // Raw key strings predate the Defaults migration — keep them byte-identical
    // so existing users' stored values survive.
    static let historyLimit = Key<Int>("historyLimit", default: 1000, suite: AppPreferenceStorage.suite)
    static let restoreClipboard = Key<Bool>(
        "restoreClipboardAfterPaste",
        default: true,
        suite: AppPreferenceStorage.suite
    )
    static let excludedBundleIDs = Key<String>(
        "excludedBundleIDs",
        default: ClipboardMonitor.defaultExclusions.sorted().joined(separator: "\n"), suite: AppPreferenceStorage.suite
    )
    static let plainTextBundleIDs = Key<String>(
        "plainTextBundleIDs",
        default: "com.apple.Terminal\ncom.googlecode.iterm2", suite: AppPreferenceStorage.suite
    )
    /// Auto-transform-on-copy rules, one "bundleID = transform" per line
    /// (transform is a ClipTransform raw value, e.g. stripTrackingParams).
    static let autoTransformRules = Key<String>("autoTransformRules", default: "", suite: AppPreferenceStorage.suite)
    /// Indexed file results in the launcher bar.
    static let launcherFileResults = Key<Bool>("launcherFileResults", default: true, suite: AppPreferenceStorage.suite)
    /// Clipboard-history results in the launcher bar.
    static let launcherClipResults = Key<Bool>("launcherClipResults", default: true, suite: AppPreferenceStorage.suite)
    /// Snippet results in the launcher bar.
    static let launcherSnippetResults = Key<Bool>(
        "launcherSnippetResults",
        default: true,
        suite: AppPreferenceStorage.suite
    )
    /// System Settings pane results in the launcher bar.
    static let launcherSettingsResults = Key<Bool>(
        "launcherSettingsResults",
        default: true,
        suite: AppPreferenceStorage.suite
    )
    /// Spotify now-playing row pinned to the bottom of the launcher.
    static let launcherNowPlaying = Key<Bool>("launcherNowPlaying", default: true, suite: AppPreferenceStorage.suite)
    /// Upcoming calendar events results (and the pinned up-next row) in the
    /// launcher.
    static let launcherCalendarEvents = Key<Bool>(
        "launcherCalendarEvents",
        default: true,
        suite: AppPreferenceStorage.suite
    )
    /// Launcher app-search aliases, one "alias = App Name" per line.
    static let launcherAppAliases = Key<String>("launcherAppAliases", default: "", suite: AppPreferenceStorage.suite)
    /// User-defined launcher quicklinks, one `keyword = URL` (or `keyword = Name | URL`)
    /// per line; `{query}` is replaced by the rest of the query.
    static let launcherQuicklinks = Key<String>("launcherQuicklinks", default: "", suite: AppPreferenceStorage.suite)
    /// Recent launcher search queries, most-recent last; de-duped and capped.
    static let launcherSearchHistory = Key<[String]>(
        "launcherSearchHistory",
        default: [],
        suite: AppPreferenceStorage.suite
    )
    /// Normalized query + result id -> successful uses; bounded by the learner.
    static let launcherSelectionUsage = Key<[String: Int]>(
        "launcherSelectionUsage",
        default: [:],
        suite: AppPreferenceStorage.suite
    )
    static let launcherItemUseCounts = Key<[String: Int]>(
        "launcherItemUseCounts",
        default: [:],
        suite: AppPreferenceStorage.suite
    )
    static let launcherItemLastUsed = Key<[String: Double]>(
        "launcherItemLastUsed",
        default: [:],
        suite: AppPreferenceStorage.suite
    )
    static let fileSearchRoots = Key<[String]>("fileSearchRoots", default: [], suite: AppPreferenceStorage.suite)
    static let fileSearchExclusions = Key<String>(
        "fileSearchExclusions",
        default: ".git\nnode_modules\n.build\nbuild\ndist\ntarget\nDerivedData\n.cache\n.Trash",
        suite: AppPreferenceStorage.suite
    )
    /// Unsaved draft text for the Files settings tab's included-folders editor.
    /// The tab only commits typed edits on "Apply & Rebuild Index" (rebuilding
    /// the index is expensive), so this mirrors keystrokes as they happen —
    /// switching tabs or relaunching mid-edit no longer discards them. Empty
    /// string means "no draft"; the tab falls back to the persisted value.
    static let fileSearchRootsDraft = Key<String>(
        "fileSearchRootsDraft",
        default: "",
        suite: AppPreferenceStorage.suite
    )
    /// Unsaved draft text for the excluded-folders editor; same purpose as
    /// `fileSearchRootsDraft`.
    static let fileSearchExclusionsDraft = Key<String>(
        "fileSearchExclusionsDraft",
        default: "",
        suite: AppPreferenceStorage.suite
    )
    /// Pinned drawer searches (raw query strings), shown as chips above history.
    static let savedSearches = Key<[String]>("savedSearches", default: [], suite: AppPreferenceStorage.suite)
    /// Emoji picked in the emoji picker, most-recent first, capped by
    /// EmojiRecents.cap — drives the picker's "Recently Used" section.
    static let emojiRecents = Key<[String]>("emojiRecents", default: [], suite: AppPreferenceStorage.suite)
    /// False until the Welcome window has been seen (Done, or closed any other
    /// way). Gates the first-launch Welcome window; the menu item reopens it
    /// regardless.
    static let hasCompletedOnboarding = Key<Bool>(
        "hasCompletedOnboarding",
        default: false,
        suite: AppPreferenceStorage.suite
    )
    /// How many times the copy-only paste HUD has explained the missing
    /// Accessibility permission. Past `PermissionService`'s limit the HUD
    /// shrinks back to the short reminder.
    static let accessibilityHintsShown = Key<Int>(
        "accessibilityHintsShown",
        default: 0,
        suite: AppPreferenceStorage.suite
    )
}

/// Parsed views over the newline-list preference keys.
public nonisolated enum Preferences {
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
