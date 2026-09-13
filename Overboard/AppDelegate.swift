import AppKit
import OverboardCore
import OverboardUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once `AppServices.shared.start()` actually runs. `shared` is a
    /// lazy `static let`, so merely *referencing* it from
    /// `applicationWillTerminate` would construct the whole store/monitor/
    /// hotkey graph for an instance that never started one — which is exactly
    /// what happens on the single-instance-guard's early-exit path below
    /// (`NSApp.terminate(nil)` still runs the standard termination sequence,
    /// including this delegate callback, before the process actually exits).
    private var servicesStarted = false

    func applicationDidFinishLaunching(_: Notification) {
        // Single-instance guard (release only — DEBUG/demo builds intentionally
        // run alongside a daily driver). Two copies launched from different paths
        // are distinct to Launch Services but share one bundle id; without this
        // both would register the same global hotkeys and run a second capture
        // pipeline against the same DB. Defer to the instance already running.
        #if !DEBUG
            if let existing = Self.otherRunningInstance() {
                existing.activate()
                NSApp.terminate(nil)
                return
            }
        #endif

        AppServices.shared.start()
        self.servicesStarted = true
        // A menu-bar app opens nothing on launch, so a first-time user would
        // otherwise be left with a boat in the menu bar and no idea what it
        // does. Once only; the menu's "Welcome…" reopens it.
        AppServices.shared.showWelcomeIfNeeded()

        #if DEBUG
            self.installDebugHooks()
        #endif
    }

    func applicationWillTerminate(_: Notification) {
        guard self.servicesStarted else { return }
        AppServices.shared.stop()
    }

    #if !DEBUG
        private static func otherRunningInstance() -> NSRunningApplication? {
            guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
            let mine = NSRunningApplication.current.processIdentifier
            return NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .first { $0.processIdentifier != mine }
        }
    #endif

    #if DEBUG
        /// Scriptable control surface for development:
        ///   swift -e 'import Foundation;
        ///     DistributedNotificationCenter.default().postNotificationName(
        ///       .init("com.nickysemenza.overboard.debug"), object: "toggle",
        ///       userInfo: nil, deliverImmediately: true)'
        /// Commands: "toggle", "show", "hide", "commit".
        /// Demo mode listens on `…overboard.demo` instead, so a concurrently
        /// running daily-driver DEBUG build doesn't mirror every command.
        private func installDebugHooks() {
            let name = AppServices.isDemo
                ? "com.nickysemenza.overboard.demo"
                : "com.nickysemenza.overboard.debug"
            DistributedNotificationCenter.default().addObserver(
                forName: .init(name),
                object: nil,
                queue: .main
            ) { notification in
                let command = notification.object as? String
                obTrace("debug command received: \(command ?? "nil")")
                MainActor.assumeIsolated {
                    Self.handleDebugCommand(command)
                }
            }
        }

        /// Dispatches one debug command. The three query/scope commands carry a
        /// payload after the first colon (e.g. "launcher-query:21*2"); every
        /// other command is a fixed name looked up in a table so adding one
        /// doesn't add a branch here. Keep the exact command names —
        /// `scripts/demo-screenshots.sh` sends them.
        @MainActor
        private static func handleDebugCommand(_ command: String?) {
            let overlay = AppServices.shared.overlay
            let launcher = AppServices.shared.launcher
            let emoji = AppServices.shared.emojiPicker

            if let command, command.hasPrefix("launcher-query:") {
                launcher.setQuery(String(command.dropFirst("launcher-query:".count)))
                return
            }
            if let command, command.hasPrefix("launcher-scope:"),
               let scope = LauncherScope(rawValue: String(command.dropFirst("launcher-scope:".count)))
            {
                AppServices.shared.launcherViewModel.setScope(scope)
                return
            }
            if let command, command.hasPrefix("emoji-query:") {
                emoji.setQuery(String(command.dropFirst("emoji-query:".count)))
                return
            }
            guard let command else { return }
            Self.debugCommandActions(overlay: overlay, launcher: launcher, emoji: emoji)[command]?()
        }

        private static func debugCommandActions(
            overlay: OverlayController,
            launcher: LauncherPanelController,
            emoji: EmojiPanelController
        ) -> [String: () -> Void] {
            [
                "toggle": { overlay.toggle() },
                "show": { overlay.show() },
                "hide": { overlay.hide() },
                "commit": { overlay.commitSelection() },
                "commit-plain": { overlay.commitSelection(mode: .plainText) },
                "pin": { overlay.togglePinSelection() },
                "delete": { overlay.deleteSelection() },
                "preview": { overlay.togglePreviewSelection() },
                "next": { overlay.moveSelection(1) },
                "prev": { overlay.moveSelection(-1) },
                "extend": { overlay.extendSelection(1) },
                "palette": { overlay.togglePalette() },
                "stack": { overlay.addSelectedToStack() },
                "appearance-light": { NSApp.appearance = NSAppearance(named: .aqua) },
                "appearance-dark": { NSApp.appearance = NSAppearance(named: .darkAqua) },
                "launcher-toggle": { launcher.toggle() },
                "launcher-show": { launcher.show() },
                "launcher-browse": { launcher.show(scope: .clipboard, query: "") },
                "launcher-preview": { AppServices.shared.launcherViewModel.togglePreview() },
                "launcher-palette": { AppServices.shared.launcherViewModel.togglePalette() },
                "launcher-hide": { launcher.hide() },
                "launcher-commit": { launcher.commitSelection() },
                "launcher-commit-cmd": { launcher.commitSelection(modifier: .command) },
                "launcher-commit-opt": { launcher.commitSelection(modifier: .option) },
                "launcher-next": { launcher.moveSelection(1) },
                "launcher-prev": { launcher.moveSelection(-1) },
                "emoji-toggle": { emoji.toggle() },
                "emoji-show": { emoji.show() },
                "emoji-hide": { emoji.hide() },
                "emoji-commit": { emoji.commitSelection() },
                "emoji-commit-cmd": { emoji.commitSelection(copyOnly: true) },
                "emoji-next": { emoji.moveSelection(.right) },
                "emoji-prev": { emoji.moveSelection(.left) },
                "emoji-down": { emoji.moveSelection(.down) },
                "emoji-up": { emoji.moveSelection(.up) },
            ]
        }
    #endif
}
