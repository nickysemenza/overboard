import AppKit
import KeyboardShortcuts
import OverboardCore
import OverboardMac
import ServiceManagement
import SwiftUI

public enum SettingsKeys {
    public static let historyLimit = "historyLimit"
    public static let restoreClipboard = "restoreClipboardAfterPaste"
    public static let excludedBundleIDs = "excludedBundleIDs"
    public static let plainTextBundleIDs = "plainTextBundleIDs"
    /// Minutes before detected secrets are hard-deleted; 0 disables expiry.
    public static let secretTTLMinutes = "secretTTLMinutes"
    /// Apple Intelligence features: auto-titles, categories, AI transforms.
    public static let aiFeatures = "aiFeatures"

    public static var defaults: [String: Any] {
        [
            historyLimit: 1000,
            restoreClipboard: true,
            excludedBundleIDs: ClipboardMonitor.defaultExclusions.sorted().joined(separator: "\n"),
            plainTextBundleIDs: "com.apple.Terminal\ncom.googlecode.iterm2",
            secretTTLMinutes: 10,
            aiFeatures: true,
        ]
    }

    public static func currentExclusions() -> Set<String> {
        self.bundleIDSet(forKey: self.excludedBundleIDs)
    }

    /// Apps where pasted text should always be plain (terminals etc.).
    public static func currentPlainTextApps() -> Set<String> {
        self.bundleIDSet(forKey: self.plainTextBundleIDs)
    }

    private static func bundleIDSet(forKey key: String) -> Set<String> {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
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
    @AppStorage(SettingsKeys.plainTextBundleIDs) private var plainTextBundleIDs = ""
    @AppStorage(SettingsKeys.secretTTLMinutes) private var secretTTLMinutes = 10
    @AppStorage(SettingsKeys.aiFeatures) private var aiFeatures = true
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

                Picker("Expire detected secrets after", selection: self.$secretTTLMinutes) {
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("30 minutes").tag(30)
                    Text("Never").tag(0)
                }
            }

            Section {
                Toggle("Apple Intelligence titles, categories & transforms", isOn: self.$aiFeatures)
                    .disabled(!ClipEnricher.isAvailable)
            } footer: {
                Text(ClipEnricher.isAvailable
                    ? "Clips get short titles and category badges, and the card menu gains AI transforms (summarize, fix grammar, …). Everything runs on-device."
                    : "Requires Apple Silicon, macOS 26, and Apple Intelligence enabled. Image OCR works regardless.")
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

            Section {
                TextEditor(text: self.$plainTextBundleIDs)
                    .font(.body.monospaced())
                    .frame(minHeight: 70)
            } header: {
                Text("Always paste as plain text into")
            } footer: {
                Text("One bundle identifier per line. Pasting text into these apps (terminals, editors) strips formatting automatically.")
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
