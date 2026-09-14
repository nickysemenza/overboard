import AppKit
import ApplicationServices
import CoreServices
import Foundation
import OverboardCore

/// What macOS currently says about one permission. `unknown` is a real third
/// state for Automation: TCC has neither granted nor denied it yet, so asking
/// would show the consent dialog.
public nonisolated enum PermissionState: Sendable, Equatable {
    case granted
    case denied
    case unknown
}

/// An app whose Automation (Apple Events) permission Overboard can ask for.
public nonisolated struct AutomationTarget: Sendable, Equatable, Identifiable {
    public let name: String
    public let bundleID: String

    public var id: String {
        self.bundleID
    }

    public init(name: String, bundleID: String) {
        self.name = name
        self.bundleID = bundleID
    }
}

/// The permissions Overboard can ask for, and what they're worth.
///
/// Accessibility is an upgrade, not a gate: every feature except ⌘V synthesis
/// works without it. Automation is per-app and only powers back-to-source
/// provenance. Both are read once this model is first touched and re-read on
/// every `refresh()` — TCC state changes in System Settings, behind our back,
/// so app activation counts as a refresh too.
@Observable
@MainActor
public final class PermissionService {
    public static let shared = PermissionService()

    public private(set) var accessibility: PermissionState = .unknown

    /// EventKit's full-access state, read from `CalendarSource.authorization`.
    public private(set) var calendar: PermissionState = .unknown

    /// Per-bundle-ID Automation state; a missing entry means "not read yet".
    public private(set) var automationStates: [String: PermissionState] = [:]

    /// The Automation rows worth showing: supported apps that are installed.
    /// Stored rather than computed so a Settings redraw doesn't re-hit Launch
    /// Services, and so a stubbed instance can report a fixed list.
    public private(set) var visibleAutomationTargets: [AutomationTarget] = []

    /// Stubbed instances never touch TCC, Launch Services, or notifications —
    /// `refresh()` keeps the injected values so snapshots stay identical on any
    /// Mac, whatever it actually has installed and granted.
    private let isStubbed: Bool

    private var activationObserver: NSObjectProtocol?

    /// Private: the live instance is `shared`, whose lifetime is the process's,
    /// so the activation observer below never needs tearing down.
    private init() {
        self.isStubbed = false
        // TCC can change while we're running (the user flips a switch in System
        // Settings and comes back), and nothing notifies us — re-activation is
        // the closest signal there is.
        self.activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        self.refresh()
    }

    /// Test seam: fixed states, no system calls. `visibleAutomationTargets`
    /// becomes exactly the seeded apps, in supported order.
    public init(
        accessibility: PermissionState,
        automation: [String: PermissionState] = [:],
        calendar: PermissionState = .unknown
    ) {
        self.isStubbed = true
        self.accessibility = accessibility
        self.automationStates = automation
        self.calendar = calendar
        self.visibleAutomationTargets = Self.supportedAutomationTargets
            .filter { automation[$0.bundleID] != nil }
    }

    // MARK: - Accessibility

    /// Whether ⌘V synthesis is allowed right now. Static (and re-read every
    /// call) because the paste path asks on every paste, from contexts that
    /// hold no reference to the model.
    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    private static var hasPromptedThisLaunch = false

    /// Shows the system Accessibility prompt at most once per launch.
    public static func promptIfNeeded() {
        guard !self.isTrusted, !self.hasPromptedThisLaunch else { return }
        self.hasPromptedThisLaunch = true
        self.promptForAccessibility()
    }

    /// Asks macOS for Accessibility, which shows the system prompt offering to
    /// open System Settings. Unlike `promptIfNeeded` this is an explicit user
    /// action, so it isn't rate-limited.
    public func requestAccessibility() {
        Self.promptForAccessibility()
        self.refresh()
    }

    private static func promptForAccessibility() {
        // Literal key because kAXTrustedCheckOptionPrompt (a global Unmanaged
        // CFString) isn't concurrency-safe to reference under Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    public func openAccessibilitySettings() {
        Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    public func openFullDiskAccessSettings() {
        Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    // MARK: - Calendar

    /// Shows the system consent dialog for full Calendar access. Only called
    /// from an explicit user action (Settings → Permissions, or the Welcome
    /// window) — never from the launcher itself.
    public func requestCalendar() {
        guard !self.isStubbed else { return }
        Task { [weak self] in
            self?.calendar = await CalendarSource.requestAccess()
        }
    }

    public func openCalendarSettings() {
        Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Automation

    /// Every app whose Automation permission is worth asking about: the
    /// browsers that back-to-source can script, plus Spotify for now-playing.
    /// Derived from the two feature owners so the list can't drift from what
    /// the features actually talk to.
    public nonisolated static let supportedAutomationTargets: [AutomationTarget] =
        BrowserScript.scriptableBrowsers.map { AutomationTarget(name: $0.name, bundleID: $0.bundleID) }
            + [
                AutomationTarget(name: "Spotify", bundleID: SpotifyNowPlayingMonitor.spotifyBundleID),
                AutomationTarget(name: "System Events", bundleID: SystemActionService.systemEventsBundleID),
            ]

    public func automation(for bundleID: String) -> PermissionState {
        self.automationStates[bundleID] ?? .unknown
    }

    /// Asks TCC for Automation on one app, showing the consent dialog when the
    /// user hasn't decided yet. Off the main actor: the check is a synchronous
    /// Apple Event round-trip that blocks until the user answers.
    public func requestAutomation(for bundleID: String) {
        guard !self.isStubbed else { return }
        Task { [weak self] in
            let state = await Task.detached {
                Self.readAutomation(bundleID: bundleID, askUserIfNeeded: true)
            }.value
            self?.automationStates[bundleID] = state
        }
    }

    // MARK: - Refresh

    /// Re-reads every permission. Cheap for Accessibility (a local check) and
    /// deferred for Automation, whose per-app TCC reads are synchronous C calls.
    public func refresh() {
        guard !self.isStubbed else { return }
        self.accessibility = AXIsProcessTrusted() ? .granted : .denied
        self.calendar = CalendarSource.authorization
        let targets = Self.supportedAutomationTargets.filter { Self.isInstalled($0.bundleID) }
        self.visibleAutomationTargets = targets
        let bundleIDs = targets.map(\.bundleID)
        Task { [weak self] in
            let states = await Task.detached {
                bundleIDs.reduce(into: [String: PermissionState]()) { result, id in
                    result[id] = Self.readAutomation(bundleID: id, askUserIfNeeded: false)
                }
            }.value
            self?.automationStates = states
        }
    }

    private static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Reads one app's Automation permission without sending a real command.
    /// `askUserIfNeeded: false` never shows UI, so it's safe on every refresh.
    private nonisolated static func readAutomation(bundleID: String, askUserIfNeeded: Bool) -> PermissionState {
        var descriptor = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        guard AECreateDesc(typeApplicationBundleID, bytes, bytes.count, &descriptor) == noErr else {
            return .unknown
        }
        defer { AEDisposeDesc(&descriptor) }
        let status = AEDeterminePermissionToAutomateTarget(
            &descriptor, typeWildCard, typeWildCard, askUserIfNeeded
        )
        switch status {
        case noErr:
            return .granted
        // -1743 errAEEventNotPermitted: the user said no, or TCC has no record
        // and we asked not to prompt.
        case -1743:
            return .denied
        // -1744 errAEEventWouldRequireUserConsent: undecided; -600 procNotFound:
        // the app isn't running, so TCC can't answer yet. Neither is a refusal.
        default:
            return .unknown
        }
    }

    // MARK: - Copy-only fallback

    /// How many times the copy-only HUD spells out why direct paste didn't
    /// happen before shrinking to the short reminder. Teach once, then get out
    /// of the way.
    private static let accessibilityHintLimit = 3

    /// HUD text for a paste that fell back to copy-only. Consumes one of the
    /// explanatory showings each time it returns the long form.
    public static func copyOnlyPasteMessage() -> String {
        let shown = Defaults[.accessibilityHintsShown]
        guard shown < self.accessibilityHintLimit else {
            return "Copied — press ⌘V to paste"
        }
        Defaults[.accessibilityHintsShown] = shown + 1
        return "Copied — grant Accessibility for direct paste"
    }
}
