import OverboardUI
import SwiftUI

@main
struct OverboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    private let updates = AppServices.shared.updates

    var body: some Scene {
        MenuBarExtra {
            if let tag = self.updates.availableTag {
                Button("Download \(tag)…") {
                    AppServices.shared.updates.openReleasePage()
                }
                Divider()
            }

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

            // Not SettingsLink: it can't raise an already-open Settings window
            // sitting behind another app (a menu-bar app can't self-activate).
            // AppServices.openSettings handles create / re-show / front uniformly.
            Button("Settings…") {
                AppServices.openSettings()
            }
            .keyboardShortcut(",")

            Button("Quit Overboard") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            MenuBarLabel(signal: AppServices.shared.signal, updates: self.updates)
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

/// The boat bounces whenever something is captured, and gains a badge when a
/// newer release is waiting to be downloaded.
private struct MenuBarLabel: View {
    let signal: CaptureSignal
    let updates: UpdateChecker

    var body: some View {
        Image(systemName: self.updates.availableTag != nil ? "sailboat.fill.circle" : "sailboat.fill")
            .symbolEffect(.bounce, value: self.signal.count)
    }
}
