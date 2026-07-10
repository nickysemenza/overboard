import AppKit
import Defaults
import KeyboardShortcuts
import os
import OverboardCore
import OverboardMac
import ServiceManagement
import SwiftUI

private let settingsLogger = Logger(subsystem: "com.nickysemenza.overboard", category: "settings")

extension ItemKind {
    /// Capitalized display name for Settings UI.
    var displayName: String {
        switch self {
        case .text: "Text"
        case .link: "Link"
        case .image: "Image"
        case .file: "File"
        case .color: "Color"
        }
    }

    /// SF Symbol representing this kind in Settings UI.
    var symbolName: String {
        switch self {
        case .text: "textformat"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        case .color: "paintpalette"
        }
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
            ActionsSettingsTab()
                .tabItem { Label("Actions", systemImage: "wand.and.stars") }
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 600)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Default(.restoreClipboard) private var restoreClipboard
    @Default(.launcherFileResults) private var launcherFileResults
    @Default(.launcherClipResults) private var launcherClipResults
    @Default(.launcherSnippetResults) private var launcherSnippetResults
    @Default(.launcherSettingsResults) private var launcherSettingsResults
    @Default(.launcherNowPlaying) private var launcherNowPlaying
    @Default(.launcherAppAliases) private var launcherAppAliases
    @Default(.updateCheckEnabled) private var updateCheckEnabled
    @Default(.richLinkPreviews) private var richLinkPreviews
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var accessibilityGranted = PermissionService.isTrusted

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Summon drawer", name: .toggleDrawer)
                KeyboardShortcuts.Recorder("Paste next from stack", name: .pasteNextFromStack)
                KeyboardShortcuts.Recorder("Summon launcher", name: .toggleLauncher)
            }

            Section {
                Toggle("Show snippet results in launcher", isOn: self.$launcherSnippetResults)
                Toggle("Show clipboard history in launcher", isOn: self.$launcherClipResults)
                Toggle("Show file results in launcher", isOn: self.$launcherFileResults)
                Toggle("Show system settings in launcher", isOn: self.$launcherSettingsResults)
                Toggle("Show Spotify now playing in launcher", isOn: self.$launcherNowPlaying)
                LabeledContent("App aliases") {
                    TextEditor(text: self.$launcherAppAliases)
                        .font(.body.monospaced())
                        .frame(height: 60)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
            } footer: {
                Text("The launcher always calculates and offers a web search; snippet and clipboard rows search your saved snippets and history (operators like kind:image work), file results add Spotlight hits from your home folder, and system settings rows open macOS Settings panes (Displays, Bluetooth, Wi-Fi…). The Spotify row pins the current track to the bottom of the list — ↩ copies its share link, ⌘↩ opens Spotify. Aliases are one “sm = Sublime Merge” per line — initials like “sm” already match without one; use aliases to override or shorten further.")
            }

            Section {
                Toggle("Launch at login", isOn: self.$launchAtLogin)
                    .onChange(of: self.launchAtLogin) {
                        self.applyLaunchAtLogin()
                    }
                Toggle("Restore previous clipboard after paste", isOn: self.$restoreClipboard)
            }

            Section {
                Toggle("Fetch link titles and icons", isOn: self.$richLinkPreviews)
            } footer: {
                Text("Connects to the URLs you copy to fetch each page’s title, description, favicon, and preview image, rendered on link cards. Requests come only from your Mac; nothing is sent anywhere else. Turn this off to keep Overboard fully offline.")
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

            Section {
                LabeledContent("Version", value: AppVersion.marketing)
                LabeledContent("Build", value: AppVersion.build)
                if let git = AppVersion.gitDescribe {
                    LabeledContent("Source") {
                        HStack(spacing: 6) {
                            if AppVersion.isDirtyOrAhead {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                            Text(git).font(.body.monospaced())
                        }
                    }
                }
                Toggle("Check for updates automatically", isOn: self.$updateCheckEnabled)
                Button("Copy version info") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AppVersion.summary, forType: .string)
                }
            } header: {
                Text("About")
            } footer: {
                Text("“Version” is the tagged release this build descends from; it only changes when a release is cut. “Source” is the exact git state it was built from — \(AppVersion.isDirtyOrAhead ? "this build is ahead of, or dirty against, that tag." : "matching the tag means it’s a clean release build."). Update checks look at GitHub Releases once a day; installing stays a manual download.")
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

    @Default(.historyLimit) private var historyLimit
    @Default(.secretTTLMinutes) private var secretTTLMinutes
    @State private var diskUsage: String?
    @State private var stats: LibraryStats?
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
                LabeledContent("Items", value: self.stats?.total.formatted() ?? "—")
                LabeledContent("On disk", value: self.diskUsage ?? "—")
                Button("Clear History…", role: .destructive) {
                    self.confirmingClear = true
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Clearing removes all unpinned items. Pinned items and snippets are kept.")
            }

            if let stats = self.stats, !stats.byKind.isEmpty {
                Section("By type") {
                    ForEach(stats.byKind) { entry in
                        LabeledContent {
                            Text(entry.count.formatted())
                        } label: {
                            Label(entry.kind.displayName, systemImage: entry.kind.symbolName)
                        }
                    }
                }
            }

            if let stats = self.stats, !stats.bySource.isEmpty {
                Section("Top sources") {
                    ForEach(stats.bySource) { entry in
                        LabeledContent(entry.app, value: entry.count.formatted())
                    }
                }
            }

            if let stats = self.stats, !stats.largest.isEmpty {
                Section {
                    ForEach(stats.largest) { item in
                        LabeledContent {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteSize), countStyle: .file))
                                .monospacedDigit()
                        } label: {
                            Label(item.label, systemImage: item.kind.symbolName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                } header: {
                    Text("Largest items")
                } footer: {
                    Text("The heaviest clips in your history — usually images. Delete these first if storage grows.")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Clear clipboard history?",
            isPresented: self.$confirmingClear
        ) {
            Button("Clear History", role: .destructive) {
                Task {
                    do {
                        try await self.store.purge(keepingLatest: 0)
                    } catch {
                        settingsLogger.error(
                            "clear history failed: \(String(describing: error), privacy: .public)"
                        )
                    }
                    await self.refresh()
                }
            }
        } message: {
            Text("All unpinned items will be deleted. This can't be undone.")
        }
        .task {
            await self.refresh()
        }
    }

    private func refresh() async {
        await self.refreshDiskUsage()
        self.stats = try? await self.store.libraryStats()
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
    @Default(.excludedBundleIDs) private var excludedBundleIDs
    @Default(.plainTextBundleIDs) private var plainTextBundleIDs
    @Default(.autoTransformRules) private var autoTransformRules

    private var transformList: String {
        ClipTransform.allCases.map(\.rawValue).joined(separator: ", ")
    }

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

            Section {
                TextEditor(text: self.$autoTransformRules)
                    .font(.body.monospaced())
                    .frame(height: 72)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            } header: {
                Text("Clean up copies from")
            } footer: {
                Text("One “bundleID = transform” per line — e.g. “com.apple.Safari = stripTrackingParams” strips ?utm_… from every link you copy in Safari. Transforms run at capture time on the plain-text copy. Available: \(self.transformList).")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Actions

/// Read-only matrix of which actions apply to which content kinds, rendered
/// straight from `ClipAction.info` so it can't drift from real behavior.
private struct ActionsSettingsTab: View {
    private let kinds = ItemKind.allCases
    private let kindColumnWidth: CGFloat = 44

    var body: some View {
        Form {
            Section {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                    GridRow {
                        Color.clear.frame(height: 0)
                            .gridColumnAlignment(.leading)
                        ForEach(self.kinds, id: \.self) { kind in
                            VStack(spacing: 2) {
                                Image(systemName: kind.symbolName)
                                Text(kind.displayName)
                                    .font(.caption2)
                            }
                            .foregroundStyle(.secondary)
                            .frame(width: self.kindColumnWidth)
                            .gridColumnAlignment(.center)
                        }
                        Text("When")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    ForEach(ClipAction.allCases) { action in
                        let info = action.info
                        GridRow {
                            VStack(alignment: .leading, spacing: 1) {
                                Label(action.label, systemImage: action.systemImage)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                if let condition = info.condition {
                                    Text(condition)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .padding(.leading, 22)
                                }
                            }
                            .gridColumnAlignment(.leading)
                            ForEach(self.kinds, id: \.self) { kind in
                                self.cell(applies: info.kinds.isEmpty || info.kinds.contains(kind))
                                    .frame(width: self.kindColumnWidth)
                                    .gridColumnAlignment(.center)
                            }
                            Text(Self.selectionLabel(info.selection))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Applies to")
            } footer: {
                Text("A checkmark means the action can apply to that content kind; “When” is how many items must be selected (single / 2+ / any). Greyed conditions are extra checks run against the clip's contents when you open the menu.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func cell(applies: Bool) -> some View {
        if applies {
            Image(systemName: "checkmark")
                .foregroundStyle(.green)
        } else {
            Text("–")
                .foregroundStyle(.quaternary)
        }
    }

    private static func selectionLabel(_ selection: ClipActionInfo.Selection) -> String {
        switch selection {
        case .single: "single"
        case .multi: "2+"
        case .any: "any"
        }
    }
}

// MARK: - AI

private struct AISettingsTab: View {
    @Default(.aiFeatures) private var aiFeatures

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
