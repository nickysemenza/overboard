import OverboardUI
import SwiftUI

@main
struct OverboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("Overboard", systemImage: "sailboat.fill") {
            Button("Show Drawer") {
                AppServices.shared.overlay.show()
            }

            Button("History…") {
                self.openWindow(id: "history")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("h")

            Button("Snippets…") {
                self.openWindow(id: "snippets")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            SettingsLink {
                Text("Settings…")
            }
            .keyboardShortcut(",")

            Button("Quit Overboard") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }

        Window("Overboard History", id: "history") {
            HistoryDebugView(store: AppServices.shared.store)
                .frame(minWidth: 420, minHeight: 320)
        }
        .defaultSize(width: 520, height: 600)

        Window("Snippets", id: "snippets") {
            SnippetsManagerView(store: AppServices.shared.store)
                .frame(minWidth: 540, minHeight: 360)
        }
        .defaultSize(width: 640, height: 420)

        Settings {
            SettingsView()
        }
    }
}
