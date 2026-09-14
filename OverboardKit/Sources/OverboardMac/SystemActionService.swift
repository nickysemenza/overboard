import AppKit
import Foundation
import OverboardCore

/// Runs the macOS system actions offered as launcher rows: lock, sleep, and
/// restart.
///
/// Lock has no public "lock right now" API, so it calls a private but
/// long-stable login.framework symbol directly. Sleep and restart instead script System Events — which is
/// why `systemEventsBundleID` exists: the first sleep/restart shows the
/// System Events Automation consent prompt, and Settings → Permissions lists
/// it as a target so a "denied" state is recoverable without hunting through
/// System Settings.
public final class SystemActionService {
    public static let shared = SystemActionService()

    /// System Events' bundle ID — the Automation target the sleep/restart
    /// AppleScript is sent to, surfaced in `PermissionService` so a denial
    /// shows up in Settings → Permissions. nonisolated: referenced from
    /// `PermissionService.supportedAutomationTargets`, itself a nonisolated
    /// static computed once at load time.
    public nonisolated static let systemEventsBundleID = "com.apple.systemevents"

    /// Whether the private lock symbol resolved. `SystemActionProvider` hides
    /// the Lock Screen row entirely when this is false, rather than offering
    /// a row that silently does nothing — nonisolated because that provider's
    /// `isAvailable` closure runs off the main actor, inside `QueryRouter`'s
    /// task group.
    public nonisolated static let canLockScreen: Bool = lockScreenFunction != nil

    /// The private, but ABI-stable, immediate-lock entry point, resolved once
    /// via `dlopen`/`dlsym` rather than on every Lock Screen tap. This is the
    /// only place in Overboard that touches a private symbol — keeping the
    /// lookup here means a future macOS that renames or removes it only
    /// breaks this one initializer (silently falling back to `canLockScreen
    /// == false`), not a crash at the call site.
    private nonisolated static let lockScreenFunction: (@convention(c) () -> Int32)? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/login.framework/Versions/A/login",
            RTLD_LAZY
        ) else { return nil }
        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
    }()

    /// Reports a human-readable failure (Automation denied, script error) for
    /// the app layer to surface — OverboardMac sits below OverboardUI in the
    /// module graph, so it can't flash a HUD itself; the app target wires
    /// this to `HUDController`.
    public var onFailure: (String) -> Void = { _ in }

    /// AppleScript runs here, off the main actor, mirroring
    /// `SpotifyNowPlayingMonitor`: a slow Apple Event — or the one-time System
    /// Events consent prompt — must never block the launcher.
    private let scriptQueue = DispatchQueue(label: "com.nickysemenza.overboard.system-action")

    private init() {}

    public func perform(_ action: SystemAction) {
        switch action {
        case .lockScreen:
            _ = Self.lockScreenFunction?()
        case .sleep:
            self.runAppleScript(command: "sleep", failureVerb: "sleep")
        case .restart:
            self.runAppleScript(command: "restart", failureVerb: "restart")
        }
    }

    /// Runs `tell application "System Events" to <command>` on the serial
    /// queue and reports failure back on the main actor. macOS shows its own
    /// confirmation dialog for restart, so success needs no acknowledgment
    /// here.
    private func runAppleScript(command: String, failureVerb: String) {
        let source = "tell application \"System Events\" to \(command)"
        self.scriptQueue.async { [weak self] in
            guard !Self.run(source) else { return }
            Task { @MainActor [weak self] in
                self?.onFailure("Couldn't \(failureVerb) — allow System Events in Settings → Permissions")
            }
        }
    }

    /// Executes the script. Returns whether it ran without error.
    /// nonisolated: runs on `scriptQueue`, never on the main actor.
    private nonisolated static func run(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }
}
