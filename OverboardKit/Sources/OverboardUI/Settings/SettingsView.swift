import AppKit
import KeyboardShortcuts
import OverboardMac
import ServiceManagement
import SwiftUI

public enum SettingsKeys {
    public static let historyLimit = "historyLimit"
    public static let restoreClipboard = "restoreClipboardAfterPaste"
    public static let excludedBundleIDs = "excludedBundleIDs"

    public static var defaults: [String: Any] {
        [
            historyLimit: 1000,
            restoreClipboard: true,
            excludedBundleIDs: ClipboardMonitor.defaultExclusions.sorted().joined(separator: "\n"),
        ]
    }

    public static func currentExclusions() -> Set<String> {
        let raw = UserDefaults.standard.string(forKey: self.excludedBundleIDs) ?? ""
        return Set(
            raw.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }
}

public struct SettingsView: View {
    @AppStorage(SettingsKeys.historyLimit) private var historyLimit = 1000
    @AppStorage(SettingsKeys.restoreClipboard) private var restoreClipboard = true
    @AppStorage(SettingsKeys.excludedBundleIDs) private var excludedBundleIDs = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var accessibilityGranted = PermissionService.isTrusted

    public init() {}

    public var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Summon drawer", name: .toggleDrawer)

                Toggle("Launch at login", isOn: self.$launchAtLogin)
                    .onChange(of: self.launchAtLogin) {
                        self.applyLaunchAtLogin()
                    }

                Toggle("Restore previous clipboard after paste", isOn: self.$restoreClipboard)

                Picker("Keep history", selection: self.$historyLimit) {
                    Text("500 items").tag(500)
                    Text("1,000 items").tag(1000)
                    Text("2,000 items").tag(2000)
                    Text("5,000 items").tag(5000)
                }
            }

            Section {
                LabeledContent("Accessibility") {
                    if self.accessibilityGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Open System Settings…") {
                            self.openAccessibilitySettings()
                        }
                    }
                }
            } footer: {
                Text("Needed only for direct paste (⌘V into the previous app). Everything else works without it.")
            }

            Section {
                TextEditor(text: self.$excludedBundleIDs)
                    .font(.body.monospaced())
                    .frame(minHeight: 110)
            } header: {
                Text("Excluded apps")
            } footer: {
                Text("One bundle identifier per line. Copies made in these apps are never captured. Apps that mark their pasteboard as concealed (most password managers) are skipped automatically.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            self.accessibilityGranted = PermissionService.isTrusted
        }
    }

    private func applyLaunchAtLogin() {
        do {
            if self.launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Re-sync the toggle with reality on failure.
            self.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
