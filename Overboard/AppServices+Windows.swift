import AppKit
import OverboardCore
import OverboardMac
import OverboardUI

/// Welcome and Settings window plumbing, plus the database-open-failure alert.
extension AppServices {
    /// The Welcome window's scene id, shared by the first-run open and the
    /// menu item that reopens it.
    static let welcomeWindowID = "welcome"

    /// Shows Welcome on the very first launch. A menu-bar app has nothing else
    /// to show a new user, so this is their only introduction; every later
    /// launch skips it and the menu item reopens it on demand.
    func showWelcomeIfNeeded() {
        guard !Defaults[.hasCompletedOnboarding] else { return }
        self.showWindow(id: Self.welcomeWindowID)
    }

    /// Raises one of the app's `Window` scenes, queuing the request when
    /// SwiftUI hasn't handed us `openWindow` yet.
    func showWindow(id: String) {
        guard let open = self.openWindowByID else {
            self.pendingWindowID = id
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        open(id)
    }

    /// SwiftUI's stable identifier for the `Settings` scene's window.
    private static let settingsWindowID = "com_apple_SwiftUI_Settings_window"

    /// Pops the Settings scene from a menu-bar (LSUIElement) app — harder than it
    /// looks. The launcher is a non-activating panel, so when this fires the app
    /// is in the background, and a background accessory app can't self-activate
    /// on Sonoma (`NSApp.activate` no-ops). So:
    ///   - If the window doesn't exist (or was closed), build/re-show it via the
    ///     main menu's ⌘, key-equivalent — the one path that materializes the
    ///     SwiftUI Settings scene from our background state.
    ///   - Then `orderFrontRegardless` raises it even while we're inactive, which
    ///     is the only thing that works when Settings is already open behind
    ///     another app (⌘, / showSettingsWindow: both no-op in that case).
    ///
    /// `tab` deep-links into a specific tab via the shared `SettingsNavigation`
    /// object bound into the `SettingsView`'s `TabView` selection.
    static func openSettings(tab: SettingsTab = .general) {
        self.shared.settingsNavigation.selectedTab = tab
        NSApp.activate(ignoringOtherApps: true)
        let existing = self.settingsWindow()
        if existing == nil || existing?.isVisible == false {
            // keyCode 0x2B = ",".
            if let comma = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: 0, context: nil,
                characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 0x2B
            ) {
                NSApp.mainMenu?.performKeyEquivalent(with: comma)
            }
        }
        // Deferred so a just-created window is in `NSApp.windows` by now.
        DispatchQueue.main.async {
            guard let settings = settingsWindow() else { return }
            settings.makeKeyAndOrderFront(nil)
            settings.orderFrontRegardless()
        }
    }

    private static func settingsWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == self.settingsWindowID }
    }

    /// Surfaces a database open/migration failure as plain-language recovery
    /// guidance plus a way to get at the file, rather than the silent crash a
    /// `fatalError` gave. The
    /// app is already running on the in-memory fallback store by the time
    /// this shows, so there's nothing to lose by explaining and quitting.
    static func presentDatabaseOpenFailureAlert(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Overboard couldn't open its database"
        alert.informativeText = """
        \(error.localizedDescription)

        This usually means the database file is corrupted or was left mid-write \
        by a crash. Overboard can't run without it and will quit — moving the \
        database file aside and relaunching starts fresh (losing clipboard \
        history), or you can back it up first for support.
        """
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn, let directory = try? OverboardDatabase.defaultDirectory() {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        }
        NSApp.terminate(nil)
    }
}
