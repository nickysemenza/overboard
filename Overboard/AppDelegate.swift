import AppKit
import OverboardUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        AppServices.shared.start()

        #if DEBUG
            self.installDebugHooks()
        #endif
    }

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

                    // "launcher-query:21*2" — payload after the first colon.
                    if let command, command.hasPrefix("launcher-query:") {
                        launcher.setQuery(String(command.dropFirst("launcher-query:".count)))
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
                    default: break
                    }
                }
            }
        }
    #endif
}
