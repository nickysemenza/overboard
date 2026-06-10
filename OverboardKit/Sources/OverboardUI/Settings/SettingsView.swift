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
    private let store: ClipStore

    public init(store: ClipStore) {
        self.store = store
    }

    public var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            HistorySettingsTab(store: self.store)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            AppsSettingsTab()
                .tabItem { Label("Apps", systemImage: "app.badge.checkmark") }
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 520)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @AppStorage(SettingsKeys.restoreClipboard) private var restoreClipboard = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var accessibilityGranted = PermissionService.isTrusted

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Summon drawer", name: .toggleDrawer)
                KeyboardShortcuts.Recorder("Paste next from stack", name: .pasteNextFromStack)
            }

            Section {
                Toggle("Launch at login", isOn: self.$launchAtLogin)
                    .onChange(of: self.launchAtLogin) {
                        self.applyLaunchAtLogin()
                    }
                Toggle("Restore previous clipboard after paste", isOn: self.$restoreClipboard)
            }

            Section {
                LabeledContent("Accessibility") {
                    if self.accessibilityGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Open System Settings…") {
                            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } footer: {
                Text("Needed only for direct paste (⌘V into the previous app). Everything else works without it.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
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
}

// MARK: - History

private struct HistorySettingsTab: View {
    let store: ClipStore

    @AppStorage(SettingsKeys.historyLimit) private var historyLimit = 1000
    @AppStorage(SettingsKeys.secretTTLMinutes) private var secretTTLMinutes = 10
    @State private var diskUsage: String?
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Section {
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
                LabeledContent("On disk", value: self.diskUsage ?? "—")
                Button("Clear History…", role: .destructive) {
                    self.confirmingClear = true
                }
            } footer: {
                Text("Clearing removes all unpinned items. Pinned items and snippets are kept.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Clear clipboard history?",
            isPresented: self.$confirmingClear
        ) {
            Button("Clear History", role: .destructive) {
                Task {
                    try? await self.store.purge(keepingLatest: 0)
                    await self.refreshDiskUsage()
                }
            }
        } message: {
            Text("All unpinned items will be deleted. This can't be undone.")
        }
        .task {
            await self.refreshDiskUsage()
        }
    }

    private func refreshDiskUsage() async {
        let bytes = await Task.detached(priority: .utility) {
            Self.directorySize()
        }.value
        self.diskUsage = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Synchronous: NSEnumerator iteration isn't allowed in async contexts.
    private nonisolated static func directorySize() -> Int64 {
        guard let directory = try? OverboardDatabase.defaultDirectory(),
              let enumerator = FileManager.default.enumerator(
                  at: directory,
                  includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
              )
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize ?? 0
            total += Int64(size)
        }
        return total
    }
}

// MARK: - Apps

private struct AppsSettingsTab: View {
    @AppStorage(SettingsKeys.excludedBundleIDs) private var excludedBundleIDs = ""
    @AppStorage(SettingsKeys.plainTextBundleIDs) private var plainTextBundleIDs = ""

    var body: some View {
        Form {
            Section {
                AppListEditor(rawList: self.$excludedBundleIDs)
            } header: {
                Text("Never capture from")
            } footer: {
                Text("Copies made in these apps never enter history. Apps that mark their pasteboard as concealed (most password managers) are skipped automatically.")
            }

            Section {
                AppListEditor(rawList: self.$plainTextBundleIDs)
            } header: {
                Text("Always paste as plain text into")
            } footer: {
                Text("Pasting text into these apps (terminals, editors) strips formatting automatically.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI

private struct AISettingsTab: View {
    @AppStorage(SettingsKeys.aiFeatures) private var aiFeatures = true

    var body: some View {
        Form {
            Section {
                Toggle("Apple Intelligence titles, categories & transforms", isOn: self.$aiFeatures)
                    .disabled(!ClipEnricher.isAvailable)
            } footer: {
                Text(ClipEnricher.isAvailable
                    ? "Clips get short titles, category badges, and one-line summaries, and the card menu gains AI transforms (summarize, fix grammar, …). Everything runs on-device — nothing leaves this Mac."
                    : "Requires Apple Silicon, macOS 26, and Apple Intelligence enabled. Image OCR works regardless.")
            }

            Section {
                LabeledContent("Image OCR", value: "Always on")
            } footer: {
                Text("Copied images and screenshots are text-recognized on-device so you can search them by their contents.")
            }
        }
        .formStyle(.grouped)
    }
}
