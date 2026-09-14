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
    /// One-time flag: whether the startup backfill has already run the
    /// Cloudflare Access login-page title cleanup (`ClipStore.resetLinkMetadata`).
    /// A bug once let the fetcher store a Cloudflare Access login page's title
    /// ("Sign in ・ Cloudflare Access") as a link's title; this heals every
    /// existing user's history exactly once rather than on every launch.
    static let didResetAccessLoginPreviews = Key<Bool>("didResetAccessLoginPreviews", default: false)
    /// Every origin that has answered a link-preview fetch with a Cloudflare
    /// Access challenge on this machine, for Settings › General › Cloudflare
    /// Access. Sorted most-recently-challenged first; capped at
    /// `CloudflareAccessHost.maxRecordedHosts`. Kept in `Defaults` rather than
    /// the clipboard DB: each laptop keeps its own list of hosts and its own
    /// `cloudflared` login state.
    static let cloudflareAccessHosts = Key<[CloudflareAccessHost]>("cloudflareAccessHosts", default: [])
}

/// One origin ("https://wiki.cfdata.org") that has challenged a link-preview
/// fetch with Cloudflare Access on this machine. `CloudflaredAccessTokens.token(for:)`
/// is only ever called after such a challenge, so that's where entries get
/// recorded (see `recordChallenge`).
public nonisolated struct CloudflareAccessHost: Codable, Hashable, Identifiable, Sendable, Defaults.Serializable {
    public var origin: String
    public var firstSeen: Date
    /// The last challenge this machine *couldn't* answer from `cloudflared`'s
    /// own cache — not every challenge: a hit doesn't move this, since it
    /// means the previous sign-in still covers the host. The stored key name
    /// (`lastChallenged`, below) predates this narrower meaning and stays as
    /// it is so existing persisted data keeps loading.
    public var lastChallenged: Date
    public var lastSignedIn: Date?

    public var id: String {
        self.origin
    }

    /// `origin` without its scheme, for display ("wiki.cfdata.org" rather
    /// than "https://wiki.cfdata.org").
    public var host: String {
        Self.host(fromOrigin: self.origin)
    }

    /// True while this machine has no answer for the host: never signed in,
    /// or challenged again since. Drives the Settings status pill, the
    /// card warning, and the ⌘K "Sign in" action — all three should agree
    /// with each other, so they all read this instead of re-deriving it.
    public var needsSignIn: Bool {
        self.lastSignedIn.map { self.lastChallenged > $0 } ?? true
    }

    public init(origin: String, firstSeen: Date, lastChallenged: Date, lastSignedIn: Date? = nil) {
        self.origin = origin
        self.firstSeen = firstSeen
        self.lastChallenged = lastChallenged
        self.lastSignedIn = lastSignedIn
    }
}

public nonisolated extension CloudflareAccessHost {
    /// Bound on the persisted host list. Generous headroom rather than a real
    /// limit in practice: one entry per Access-gated internal service the
    /// user's ever copied a link to, not per link.
    static let maxRecordedHosts = 50

    /// `origin` without its scheme. A static helper (not just the `host`
    /// property) so the app target's HUD hint — which only has the origin
    /// string `CloudflaredAccessTokens` hands it, not a `CloudflareAccessHost`
    /// — can render the same short form.
    static func host(fromOrigin origin: String) -> String {
        guard let range = origin.range(of: "://") else { return origin }
        return String(origin[range.upperBound...])
    }

    /// Upserts `origin`'s challenge into `hosts` — bumping `lastChallenged`
    /// for an existing entry, appending a new one otherwise — then re-sorts
    /// most-recently-challenged first and caps the result. The pure decision
    /// behind `CloudflaredAccessTokens.token(for:)`'s `Defaults` write,
    /// factored out so it's testable without shelling out to `cloudflared`.
    static func recordChallenge(
        in hosts: [CloudflareAccessHost], origin: String, now: Date
    ) -> [CloudflareAccessHost] {
        var updated = hosts
        if let index = updated.firstIndex(where: { $0.origin == origin }) {
            updated[index].lastChallenged = now
        } else {
            updated.append(CloudflareAccessHost(origin: origin, firstSeen: now, lastChallenged: now))
        }
        updated.sort { $0.lastChallenged > $1.lastChallenged }
        return Array(updated.prefix(self.maxRecordedHosts))
    }

    /// Records a successful `cloudflared access login` for `origin`. A no-op
    /// if the host isn't in the list — sign-in only ever runs from a row
    /// Settings is already showing, which means it's already recorded.
    static func recordSignIn(
        in hosts: [CloudflareAccessHost], origin: String, now: Date
    ) -> [CloudflareAccessHost] {
        var updated = hosts
        guard let index = updated.firstIndex(where: { $0.origin == origin }) else { return updated }
        updated[index].lastSignedIn = now
        return updated
    }

    /// The recorded host `url` belongs to, but only when it still
    /// `needsSignIn` — a signed-in host has nothing to warn a link card or
    /// offer a ⌘K action about. Shared by the card warning and the palette
    /// entry so both agree on exactly which links are gated right now.
    static func gatedHost(for url: URL, in hosts: [CloudflareAccessHost]) -> CloudflareAccessHost? {
        guard let origin = CloudflaredAccessTokens.origin(for: url) else { return nil }
        return hosts.first { $0.origin == origin && $0.needsSignIn }
    }
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
