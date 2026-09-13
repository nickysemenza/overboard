import OverboardMac
import SwiftUI

struct FileSearchSettingsTab: View {
    @State private var roots = ""
    @State private var exclusions = ""
    private let service = FileIndexService.shared

    /// The persisted (last-applied) included-folders text, for dirty checking.
    private var persistedRootsText: String {
        let saved = Defaults[.fileSearchRoots]
        return (saved.isEmpty ? FileIndexService.defaultRoots.map(\.path) : saved).joined(separator: "\n")
    }

    /// True when either editor has typed edits that "Apply & Rebuild Index"
    /// hasn't committed yet.
    private var isDirty: Bool {
        self.roots != self.persistedRootsText || self.exclusions != Defaults[.fileSearchExclusions]
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: self.service.status)
                if self.service.isIndexing {
                    ProgressView().controlSize(.small)
                }
            } header: { Text("Index") } footer: {
                Text("Permission problems are listed under Permissions.")
            }
            Section {
                TextEditor(text: self.$roots).font(.body.monospaced()).frame(height: 120)
                    .accessibilityLabel("Included folders, one path per line")
                Button("Use Default Locations") {
                    self.roots = FileIndexService.defaultRoots.map(\.path).joined(separator: "\n")
                }
            } header: { Text("Included folders") } footer: {
                Text(
                    """
                    One folder path per line. Defaults include your home folder, iCloud Drive and \
                    Finder-visible cloud storage. Home excludes Library; cloud locations inside \
                    Library are included explicitly.
                    """
                )
            }
            Section {
                TextEditor(text: self.$exclusions).font(.body.monospaced()).frame(height: 110)
                    .accessibilityLabel("Excluded folder names or absolute paths, one per line")
            } header: { Text("Excluded folders") } footer: {
                Text(
                    """
                    One folder name or absolute path per line. Hidden internals and app-package \
                    contents are skipped. Only names, paths, dates and cloud availability are \
                    indexed; file contents are never read.
                    """
                )
            }
            HStack(spacing: 10) {
                Button("Apply & Rebuild Index") {
                    self.apply()
                }
                if self.isDirty {
                    Text("Unsaved changes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            self.loadDraftOrPersisted()
        }
        .onChange(of: self.roots) { _, newValue in
            Defaults[.fileSearchRootsDraft] = newValue
        }
        .onChange(of: self.exclusions) { _, newValue in
            Defaults[.fileSearchExclusionsDraft] = newValue
        }
    }

    /// Restores a pending draft (typed edits from a previous tab visit or
    /// launch) if there is one, else the persisted, applied value.
    private func loadDraftOrPersisted() {
        let draftRoots = Defaults[.fileSearchRootsDraft]
        self.roots = draftRoots.isEmpty ? self.persistedRootsText : draftRoots
        let draftExclusions = Defaults[.fileSearchExclusionsDraft]
        self.exclusions = draftExclusions.isEmpty ? Defaults[.fileSearchExclusions] : draftExclusions
    }

    private func apply() {
        Defaults[.fileSearchRoots] = self.roots.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        Defaults[.fileSearchExclusions] = self.exclusions
        // Drafts are now identical to the persisted values — clear them so a
        // stale draft never masks a future out-of-band change to the roots.
        Defaults[.fileSearchRootsDraft] = ""
        Defaults[.fileSearchExclusionsDraft] = ""
        self.service.rebuild()
    }
}
