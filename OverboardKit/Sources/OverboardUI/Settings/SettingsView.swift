import AppKit
import Defaults
import KeyboardShortcuts
import os
import OverboardCore
import OverboardMac
import ServiceManagement
import SwiftUI

private let settingsLogger = Logger(subsystem: "com.nickysemenza.overboard", category: "settings")

/// Identifies one Settings tab, so callers outside the view (a launcher
/// command, a menu item) can deep-link to a specific one.
public enum SettingsTab: Hashable, Sendable {
    case general, history, files, apps, actions, permissions, ai
}

/// Shared, externally-settable tab selection for the Settings scene. SwiftUI
/// builds the `Settings` scene once at launch, long before any window exists,
/// so there's no view instance around for a caller like
/// `AppServices.openSettings` to hand a binding to — this observable object
/// is the bridge: `SettingsView` binds its `TabView` selection to it, and a
/// caller sets `selectedTab` before raising the window.
@Observable
public final class SettingsNavigation {
    public var selectedTab: SettingsTab

    public init(selectedTab: SettingsTab = .general) {
        self.selectedTab = selectedTab
    }
}

/// Shared copy for the "clear all clipboard history" confirmation, so the
/// Settings confirmation dialog and the `:clear` launcher command's `NSAlert`
/// (which can't use a SwiftUI dialog since it runs outside a view) can't drift.
public enum ClearHistoryPrompt {
    public static let title = "Clear Clipboard History?"
    public static let message = "All unpinned items will be deleted. Pinned items are kept. This can't be undone."
    public static let confirm = "Clear History"
}

public struct SettingsView: View {
    private let store: ClipStore
    private let checkForUpdates: () async -> Void
    @Bindable private var navigation: SettingsNavigation

    public init(
        store: ClipStore,
        navigation: SettingsNavigation = SettingsNavigation(),
        checkForUpdates: @escaping () async -> Void = {}
    ) {
        self.store = store
        self.navigation = navigation
        self.checkForUpdates = checkForUpdates
    }

    public var body: some View {
        TabView(selection: self.$navigation.selectedTab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettingsTab(checkForUpdates: self.checkForUpdates)
            }
            Tab("History", systemImage: "clock.arrow.circlepath", value: SettingsTab.history) {
                HistorySettingsTab(store: self.store)
            }
            Tab("Files", systemImage: "folder", value: SettingsTab.files) {
                FileSearchSettingsTab()
            }
            Tab("Apps", systemImage: "app.badge.checkmark", value: SettingsTab.apps) {
                AppsSettingsTab()
            }
            Tab("Actions", systemImage: "wand.and.stars", value: SettingsTab.actions) {
                ActionsSettingsTab()
            }
            Tab("Permissions", systemImage: "lock.shield", value: SettingsTab.permissions) {
                PermissionsSettingsTab()
            }
            Tab("AI", systemImage: "sparkles", value: SettingsTab.ai) {
                AISettingsTab()
            }
        }
        // A fixed floor big enough for the tallest tab (History, with its
        // stats sections) so switching tabs doesn't resize the window.
        .frame(minWidth: 520, minHeight: 420)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    let checkForUpdates: () async -> Void

    @Default(.restoreClipboard) private var restoreClipboard
    @Default(.launcherFileResults) private var launcherFileResults
    @Default(.launcherClipResults) private var launcherClipResults
    @Default(.launcherSnippetResults) private var launcherSnippetResults
    @Default(.launcherSettingsResults) private var launcherSettingsResults
    @Default(.launcherNowPlaying) private var launcherNowPlaying
    @Default(.launcherAppAliases) private var launcherAppAliases
    @Default(.updateCheckEnabled) private var updateCheckEnabled
    @Default(.richLinkPreviews) private var richLinkPreviews

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Show Drawer", name: .toggleDrawer)
                KeyboardShortcuts.Recorder("Paste next from stack", name: .pasteNextFromStack)
                KeyboardShortcuts.Recorder("Show Launcher", name: .toggleLauncher)
                KeyboardShortcuts.Recorder("Show Emoji Picker", name: .toggleEmojiPicker)
            } footer: {
                Text(
                    "The emoji picker's default shortcut (⌃⌘Space) takes over the system emoji viewer's binding while Overboard is running — record a different one here to get the system viewer back."
                )
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
                Text(
                    "All mixes apps, files, clipboard, snippets, calculator, system settings, AI, and now playing. Use ⌘1–4 to switch scopes. File search locations are managed in Files. Aliases are one “sm = Sublime Merge” per line; initials work automatically."
                )
            }

            Section {
                LaunchAtLoginToggle()
                Toggle("Restore previous clipboard after paste", isOn: self.$restoreClipboard)
            }

            Section {
                Toggle("Fetch link titles and icons", isOn: self.$richLinkPreviews)
            } footer: {
                Text(
                    "Connects to the URLs you copy to fetch each page’s title, description, favicon, and preview image, rendered on link cards. Requests come only from your Mac; nothing is sent anywhere else. Turn this off to keep Overboard fully offline."
                )
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
                HStack {
                    Toggle("Check for updates automatically", isOn: self.$updateCheckEnabled)
                    Spacer()
                    Button("Check Now") {
                        Task { await self.checkForUpdates() }
                    }
                }
                Button("Copy Version Info") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AppVersion.summary, forType: .string)
                }
            } header: {
                Text("About")
            } footer: {
                Text(
                    "“Version” is the tagged release this build descends from; it only changes when a release is cut. “Source” is the exact git state it was built from — \(AppVersion.isDirtyOrAhead ? "this build is ahead of, or dirty against, that tag." : "matching the tag means it’s a clean release build."). Update checks look at GitHub Releases once a day; installing stays a manual download."
                )
            }
        }
        .formStyle(.grouped)
    }
}

/// The login-item toggle, shared by Settings → General and the Welcome window
/// so the register/unregister handling (and its failure re-sync) lives once.
struct LaunchAtLoginToggle: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Launch at login", isOn: self.$launchAtLogin)
            .onChange(of: self.launchAtLogin) {
                self.apply()
            }
    }

    private func apply() {
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
    @State private var archiveOutcome: ArchiveOutcome?
    @State private var isArchiving = false

    /// The result of an export or import, shown once in an alert. Carries its
    /// own title so success and failure share one presentation.
    private struct ArchiveOutcome: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

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
                LabeledContent("Items") {
                    Text(self.stats?.total.formatted() ?? "—")
                        .monospacedDigit()
                }
                LabeledContent("On disk", value: self.diskUsage ?? "—")
                Button("Clear History…", role: .destructive) {
                    self.confirmingClear = true
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Clearing removes all unpinned items. Pinned items and snippets are kept.")
            }

            Section {
                Button("Export History…") {
                    self.exportHistory()
                }
                Button("Import History…") {
                    self.importHistory()
                }
            } header: {
                Text("Backup")
            } footer: {
                Text(
                    "An export is a folder of readable JSON plus the large payloads it references. Detected secrets are left out — they expire on purpose. Importing skips clips you already have."
                )
            }
            .disabled(self.isArchiving)

            if let stats = self.stats, !stats.byKind.isEmpty {
                Section("By type") {
                    ForEach(stats.byKind) { entry in
                        LabeledContent {
                            Text(entry.count.formatted())
                        } label: {
                            Label {
                                Text(entry.kind.displayName)
                            } icon: {
                                // The one place the kind-identity ramp is the
                                // subject rather than incidental decoration.
                                Image(systemName: entry.kind.symbolName)
                                    .foregroundStyle(Color(entry.kind.tintName))
                            }
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
            ClearHistoryPrompt.title,
            isPresented: self.$confirmingClear
        ) {
            Button(ClearHistoryPrompt.confirm, role: .destructive) {
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
            Text(ClearHistoryPrompt.message)
        }
        .alert(
            self.archiveOutcome?.title ?? "",
            isPresented: Binding(
                get: { self.archiveOutcome != nil },
                set: {
                    if !$0 {
                        self.archiveOutcome = nil
                    }
                }
            ),
            presenting: self.archiveOutcome
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { outcome in
            Text(outcome.message)
        }
        .task {
            await self.refresh()
        }
    }

    // MARK: - Backup

    private func exportHistory() {
        // AppKit panels rather than `.fileExporter`: the archive is a folder we
        // write ourselves (JSON + blob files), not a single document SwiftUI
        // can hand off.
        let panel = NSSavePanel()
        panel.title = String(localized: "Export History")
        panel.prompt = String(localized: "Export")
        panel.nameFieldStringValue = String(localized: "Overboard Export")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        self.isArchiving = true
        Task {
            defer { self.isArchiving = false }
            do {
                let summary = try await self.store.export(to: url)
                var message = String(
                    localized: "Wrote \(CountPhrase.string(summary.itemCount, of: String(localized: "clip"))) to \(summary.directory.lastPathComponent)."
                )
                if summary.secretsExcluded > 0 {
                    message += " " + String(
                        localized: "\(CountPhrase.string(summary.secretsExcluded, of: String(localized: "detected secret"))) excluded."
                    )
                }
                if summary.blobsMissing > 0 {
                    message += " " + String(
                        localized: "\(CountPhrase.string(summary.blobsMissing, of: String(localized: "attachment"))) could not be copied."
                    )
                }
                self.archiveOutcome = ArchiveOutcome(
                    title: String(localized: "Export Complete"), message: message
                )
            } catch {
                settingsLogger.error("export failed: \(String(describing: error), privacy: .public)")
                self.archiveOutcome = ArchiveOutcome(
                    title: String(localized: "Export Failed"), message: error.localizedDescription
                )
            }
        }
    }

    private func importHistory() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import History")
        panel.prompt = String(localized: "Import")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        self.isArchiving = true
        Task {
            defer { self.isArchiving = false }
            do {
                let summary = try await self.store.import(from: url)
                var parts = [String(
                    localized: "Added \(CountPhrase.string(summary.imported, of: String(localized: "clip")))."
                )]
                if summary.duplicatesSkipped > 0 {
                    parts.append(String(
                        localized: "Skipped \(CountPhrase.string(summary.duplicatesSkipped, of: String(localized: "duplicate")))."
                    ))
                }
                // Damage is reported rather than hidden: an archive with bad
                // lines or missing payloads still imported everything it could.
                if !summary.malformedLines.isEmpty {
                    parts.append(String(
                        localized: "Couldn’t read \(CountPhrase.string(summary.malformedLines.count, of: String(localized: "line")))."
                    ))
                }
                if summary.missingBlobs > 0 {
                    parts.append(String(
                        localized: "\(CountPhrase.string(summary.missingBlobs, of: String(localized: "payload file"))) missing from the archive."
                    ))
                }
                self.archiveOutcome = ArchiveOutcome(
                    title: String(localized: "Import Complete"), message: parts.joined(separator: " ")
                )
                await self.refresh()
            } catch {
                settingsLogger.error("import failed: \(String(describing: error), privacy: .public)")
                self.archiveOutcome = ArchiveOutcome(
                    title: String(localized: "Import Failed"),
                    // "Pick a folder written by Export History" is the whole
                    // point of the message; `localizedDescription` on a plain
                    // Swift error would flatten it to "The operation couldn't
                    // be completed."
                    message: (error as? ClipArchive.Failure)?.description ?? error.localizedDescription
                )
            }
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
                Text(
                    "Copies made in these apps never enter history. Apps that mark their pasteboard as concealed (most password managers) are skipped automatically."
                )
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
                Text(
                    "One “bundleID = transform” per line — e.g. “com.apple.Safari = stripTrackingParams” strips ?utm_… from every link you copy in Safari. Transforms run at capture time on the plain-text copy. Available: \(self.transformList)."
                )
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
                                        .contrastAwareForeground(.tertiary)
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
                Text(
                    "A checkmark means the action can apply to that content kind; “When” is how many items must be selected (single / 2+ / any). Greyed conditions are extra checks run against the clip's contents when you open the menu."
                )
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
                .contrastAwareForeground(.quaternary)
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
                    : "Requires Apple Silicon with Apple Intelligence enabled. Image OCR works regardless.")
            }

            Section {
                LabeledContent("Image OCR", value: "Always on")
            } footer: {
                Text(
                    "Copied images and screenshots are text-recognized on-device so you can search them by their contents."
                )
            }
        }
        .formStyle(.grouped)
    }
}

#if DEBUG
    #Preview("All tabs") {
        SettingsView(store: Fixtures.previewStore())
    }

    #Preview("General") {
        GeneralSettingsTab(checkForUpdates: {})
            .frame(width: 600, height: 500)
    }

    #Preview("History") {
        HistorySettingsTab(store: Fixtures.previewStore())
            .frame(width: 600, height: 500)
    }

    #Preview("Apps") {
        AppsSettingsTab()
            .frame(width: 600, height: 500)
    }

    #Preview("Actions") {
        ActionsSettingsTab()
            .frame(width: 600, height: 500)
    }

    #Preview("AI") {
        AISettingsTab()
            .frame(width: 600, height: 500)
    }
#endif
