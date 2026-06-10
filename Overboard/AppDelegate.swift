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
        ///       .init("com.nicky.overboard.debug"), object: "toggle",
        ///       userInfo: nil, deliverImmediately: true)'
        /// Commands: "toggle", "show", "hide", "commit".
        private func installDebugHooks() {
            DistributedNotificationCenter.default().addObserver(
                forName: .init("com.nicky.overboard.debug"),
                object: nil,
                queue: .main
            ) { notification in
                let command = notification.object as? String
                obTrace("debug command received: \(command ?? "nil")")
                MainActor.assumeIsolated {
                    let overlay = AppServices.shared.overlay
                    switch command {
                    case "toggle": overlay.toggle()
                    case "show": overlay.show()
                    case "hide": overlay.hide()
                    case "commit": overlay.commitSelection()
                    case "commit-plain": overlay.commitSelection(mode: .plainText)
                    case "pin": overlay.togglePinSelection()
                    case "delete": overlay.deleteSelection()
                    default: break
                    }
                }
            }
        }
    #endif
}
