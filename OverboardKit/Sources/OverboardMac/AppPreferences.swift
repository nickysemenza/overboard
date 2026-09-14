// Re-exported so the app target and OverboardUI reach Defaults[...] through
// their existing OverboardMac import without a pbxproj package reference.
@_exported import Defaults
import Foundation
import OverboardCore

public nonisolated extension Defaults.Keys {
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
    /// Fetch page title/description/favicon/preview for copied links over the
    /// network to render rich link cards. User-opt-in; on by default.
    static let richLinkPreviews = Key<Bool>("richLinkPreviews", default: true)
    /// Indexed file results in the launcher bar.
    static let launcherFileResults = Key<Bool>("launcherFileResults", default: true)
    /// Clipboard-history results in the launcher bar.
    static let launcherClipResults = Key<Bool>("launcherClipResults", default: true)
    /// Snippet results in the launcher bar.
    static let launcherSnippetResults = Key<Bool>("launcherSnippetResults", default: true)
    /// System Settings pane results in the launcher bar.
    static let launcherSettingsResults = Key<Bool>("launcherSettingsResults", default: true)
    /// Spotify now-playing row pinned to the bottom of the launcher.
    static let launcherNowPlaying = Key<Bool>("launcherNowPlaying", default: true)
    /// Upcoming calendar events results (and the pinned up-next row) in the
    /// launcher.
    static let launcherCalendarEvents = Key<Bool>("launcherCalendarEvents", default: true)
    /// Launcher app-search aliases, one "alias = App Name" per line.
    static let launcherAppAliases = Key<String>("launcherAppAliases", default: "")
    /// User-defined launcher quicklinks, one `keyword = URL` (or `keyword = Name | URL`)
    /// per line; `{query}` is replaced by the rest of the query.
    static let launcherQuicklinks = Key<String>("launcherQuicklinks", default: "")
    /// Recent launcher search queries, most-recent last; de-duped and capped.
    static let launcherSearchHistory = Key<[String]>("launcherSearchHistory", default: [])
    /// Normalized query + result id -> successful uses; bounded by the learner.
    static let launcherSelectionUsage = Key<[String: Int]>("launcherSelectionUsage", default: [:])
    static let launcherItemUseCounts = Key<[String: Int]>("launcherItemUseCounts", default: [:])
    static let launcherItemLastUsed = Key<[String: Double]>("launcherItemLastUsed", default: [:])
    static let fileSearchRoots = Key<[String]>("fileSearchRoots", default: [])
    static let fileSearchExclusions = Key<String>(
        "fileSearchExclusions",
        default: ".git\nnode_modules\n.build\nbuild\ndist\ntarget\nDerivedData\n.cache\n.Trash"
    )
    /// Unsaved draft text for the Files settings tab's included-folders editor.
    /// The tab only commits typed edits on "Apply & Rebuild Index" (rebuilding
    /// the index is expensive), so this mirrors keystrokes as they happen —
    /// switching tabs or relaunching mid-edit no longer discards them. Empty
    /// string means "no draft"; the tab falls back to the persisted value.
    static let fileSearchRootsDraft = Key<String>("fileSearchRootsDraft", default: "")
    /// Unsaved draft text for the excluded-folders editor; same purpose as
    /// `fileSearchRootsDraft`.
    static let fileSearchExclusionsDraft = Key<String>("fileSearchExclusionsDraft", default: "")
    /// Pinned drawer searches (raw query strings), shown as chips above history.
    static let savedSearches = Key<[String]>("savedSearches", default: [])
    /// Emoji picked in the emoji picker, most-recent first, capped by
    /// EmojiRecents.cap — drives the picker's "Recently Used" section.
    static let emojiRecents = Key<[String]>("emojiRecents", default: [])
    /// False until the Welcome window has been seen (Done, or closed any other
    /// way). Gates the first-launch Welcome window; the menu item reopens it
    /// regardless.
    static let hasCompletedOnboarding = Key<Bool>("hasCompletedOnboarding", default: false)
    /// How many times the copy-only paste HUD has explained the missing
    /// Accessibility permission. Past `PermissionService`'s limit the HUD
    /// shrinks back to the short reminder.
    static let accessibilityHintsShown = Key<Int>("accessibilityHintsShown", default: 0)
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
