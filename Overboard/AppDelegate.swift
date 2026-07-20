import AppKit
import OverboardUI

final class AppDelegate: NSObject, NSApplicationDelegate {
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

        #if DEBUG
            self.installDebugHooks()
        #endif
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
                    let overlay = AppServices.shared.overlay
                    let launcher = AppServices.shared.launcher
                    let emoji = AppServices.shared.emojiPicker

                    // "launcher-query:21*2" — payload after the first colon.
                    if let command, command.hasPrefix("launcher-query:") {
                        launcher.setQuery(String(command.dropFirst("launcher-query:".count)))
                        return
                    }
                    if let command, command.hasPrefix("emoji-query:") {
                        emoji.setQuery(String(command.dropFirst("emoji-query:".count)))
                        return
                    }

                    switch command {
                    case "toggle": overlay.toggle()
                    case "show": overlay.show()
                    case "hide": overlay.hide()
                    case "commit": overlay.commitSelection()
                    case "commit-plain": overlay.commitSelection(mode: .plainText)
                    case "pin": overlay.togglePinSelection()
                    case "delete": overlay.deleteSelection()
                    case "preview": overlay.togglePreviewSelection()
                    case "next": overlay.moveSelection(1)
                    case "prev": overlay.moveSelection(-1)
                    case "extend": overlay.extendSelection(1)
                    case "palette": overlay.togglePalette()
                    case "stack": overlay.addSelectedToStack()
                    case "launcher-toggle": launcher.toggle()
                    case "launcher-show": launcher.show()
                    case "launcher-hide": launcher.hide()
                    case "launcher-commit": launcher.commitSelection()
                    case "launcher-commit-cmd": launcher.commitSelection(modifier: .command)
                    case "launcher-commit-opt": launcher.commitSelection(modifier: .option)
                    case "launcher-next": launcher.moveSelection(1)
                    case "launcher-prev": launcher.moveSelection(-1)
                    case "emoji-toggle": emoji.toggle()
                    case "emoji-show": emoji.show()
                    case "emoji-hide": emoji.hide()
                    case "emoji-commit": emoji.commitSelection()
                    case "emoji-commit-cmd": emoji.commitSelection(copyOnly: true)
                    case "emoji-next": emoji.moveSelection(.right)
                    case "emoji-prev": emoji.moveSelection(.left)
                    case "emoji-down": emoji.moveSelection(.down)
                    case "emoji-up": emoji.moveSelection(.up)
                    default: break
                    }
                }
            }
        }
    #endif
}
