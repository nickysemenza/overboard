import OverboardMac
import OverboardUI
import SwiftUI

@main
struct OverboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    private let captureState = AppServices.shared.captureState

    var body: some Scene {
        MenuBarExtra {
            SummonMenuItem(
                title: "Show Launcher",
                shortcutDescription: HotkeyService.toggleLauncherShortcutDescription
            ) {
                AppServices.shared.launcher.show()
            }

            SummonMenuItem(title: "Show Drawer", shortcutDescription: HotkeyService.toggleDrawerShortcutDescription) {
                AppServices.shared.overlay.show()
            }

            SummonMenuItem(
                title: "Show Emoji Picker",
                shortcutDescription: HotkeyService.toggleEmojiPickerShortcutDescription
            ) {
                AppServices.shared.emojiPicker.show()
            }

            // HistoryDebugView is a debug affordance superseded by the drawer;
            // keep it (and its ⌘H) out of release builds so a stray shortcut
            // can't open a second, unpolished full-history surface.
            #if DEBUG
                Button("History…") {
                    self.openWindow(id: "history")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("h")
            #endif

            Button("Snippets…") {
                self.openWindow(id: "snippets")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            Button(self.captureState.isPaused ? "Resume Capture" : "Pause Capture") {
                AppServices.shared.setCapturePaused(!self.captureState.isPaused)
            }

            Divider()

            Button("About Overboard") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(nil)
            }

            Button("Welcome…") {
                self.openWindow(id: AppServices.welcomeWindowID)
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
            MenuBarLabel(
                signal: AppServices.shared.signal,
                captureState: self.captureState
            )
            // The menu-bar label is the only view SwiftUI renders at launch, so
            // it's where `openWindow` first becomes reachable — see
            // `AppServices.openWindowByID`.
            .onAppear {
                AppServices.shared.openWindowByID = { self.openWindow(id: $0) }
            }
        }

        Window("Welcome to Overboard", id: AppServices.welcomeWindowID) {
            WelcomeView(
                openShortcutSettings: { AppServices.openSettings(tab: .general) },
                onDone: { Defaults[.hasCompletedOnboarding] = true }
            )
            // Closing the window any other way still counts as seen — this
            // isn't a gate, and re-showing it every launch would be a nag.
            .onDisappear { Defaults[.hasCompletedOnboarding] = true }
        }
        .defaultSize(width: 460, height: 400)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        #if DEBUG
            Window("Overboard History", id: "history") {
                HistoryDebugView(store: AppServices.shared.store)
                    .frame(minWidth: 420, minHeight: 320)
            }
            .defaultSize(width: 520, height: 600)
            .restorationBehavior(.disabled)
        #endif

        Window("Snippets", id: "snippets") {
            SnippetsManagerView(store: AppServices.shared.store)
                .frame(minWidth: 540, minHeight: 360)
        }
        .defaultSize(width: 640, height: 420)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(
                store: AppServices.shared.store,
                enrichment: AppServices.shared.enrichment,
                navigation: AppServices.shared.settingsNavigation
            )
        }
        .windowResizability(.contentSize)
    }
}

/// A menu-bar item that summons a panel (launcher / drawer / emoji picker),
/// showing its recorded global shortcut as trailing secondary text, e.g.
/// "Show Launcher  ⌥Space". These shortcuts are Carbon hotkeys owned by
/// `KeyboardShortcuts`, so this deliberately does NOT attach a
/// `.keyboardShortcut` modifier to the button — that would register a second,
/// duplicate app-level shortcut alongside the global one.
private struct SummonMenuItem: View {
    let title: String
    let shortcutDescription: String?
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            if let shortcutDescription {
                Text("\(self.title)  \(Text(shortcutDescription).foregroundStyle(.secondary))")
            } else {
                Text(self.title)
            }
        }
    }
}

/// The boat bounces whenever something is captured. While capture is paused it
/// dims to the secondary style so an off clipboard is visible at a glance.
private struct MenuBarLabel: View {
    let signal: CaptureSignal
    let captureState: CaptureState

    var body: some View {
        Image(systemName: "sailboat.fill")
            .symbolEffect(.bounce, value: self.signal.count)
            // Dim the boat while paused so an off clipboard is obvious.
            .foregroundStyle(self.captureState.isPaused ? .secondary : .primary)
            .accessibilityLabel("Overboard")
            .accessibilityValue(self.captureState.isPaused ? "Capture paused" : "Capturing")
    }
}
