import AppKit
import OverboardCore
import OverboardMac
import OverboardUI

extension AppServices {
    static let welcomeWindowID = "welcome"

    func showWelcomeIfNeeded() {
        guard self.libraryRecovery == nil, !Defaults[.hasCompletedOnboarding] else { return }
        self.showWindow(id: Self.welcomeWindowID)
    }

    func showWindow(id: String) {
        guard let open = self.openWindowByID else {
            self.pendingWindowID = id
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        open(id)
    }

    static func openSettings(tab: SettingsTab = .general) {
        NSApp.activate(ignoringOtherApps: true)
        self.shared.settingsCoordinator.show(tab: tab)
    }

    func presentLibraryRecovery() {
        guard let recovery = self.libraryRecovery else { return }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Overboard couldn't open its library"
            alert.informativeText = """
            Clipboard capture, indexing, and background processing are stopped. \
            The original library has not been replaced by an empty library.

            Reveal the library folder to inspect the database and any pre-migration \
            backups. Keep a copy before attempting repair or restoring a backup, \
            then relaunch Overboard. Do not delete the database to troubleshoot.

            \(recovery)
            """
            alert.addButton(withTitle: "Reveal Library")
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Keep Open")
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if let directory = try? OverboardDatabase.defaultDirectory() {
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                }
            case .alertSecondButtonReturn:
                NSApp.terminate(nil)
            default:
                break
            }
        }
    }
}
