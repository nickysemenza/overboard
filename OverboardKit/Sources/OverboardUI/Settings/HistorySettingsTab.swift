import AppKit
import Defaults
import os
import OverboardCore
import SwiftUI

let settingsLogger = Logger(subsystem: "com.nickysemenza.overboard", category: "settings")

struct HistorySettingsTab: View {
    let store: ClipStore

    @Default(.historyLimit) private var historyLimit
    @Default(.secretTTLMinutes) private var secretTTLMinutes
    @State private var diskUsage: String?
    @State private var stats: LibraryStats?
    @State private var confirmingClear = false
    @State var archiveOutcome: ArchiveOutcome?
    @State var isArchiving = false

    /// The result of an export or import, shown once in an alert. Carries its
    /// own title so success and failure share one presentation.
    struct ArchiveOutcome: Identifiable {
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
                    """
                    An export is a folder of readable JSON plus the large payloads it references. \
                    Detected secrets are left out — they expire on purpose. Importing skips clips \
                    you already have.
                    """
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

    func refresh() async {
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

#if DEBUG
    #Preview("History") {
        HistorySettingsTab(store: Fixtures.previewStore())
            .frame(width: 600, height: 500)
    }
#endif
