import OverboardUI
import SwiftUI

@main
struct OverboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
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
        } label: {
            MenuBarLabel(signal: AppServices.shared.signal)
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
            SettingsView(store: AppServices.shared.store)
        }
    }
}

/// The boat bounces whenever something is captured.
private struct MenuBarLabel: View {
    let signal: CaptureSignal

    var body: some View {
        Image(systemName: "sailboat.fill")
            .symbolEffect(.bounce, value: self.signal.count)
    }
}
