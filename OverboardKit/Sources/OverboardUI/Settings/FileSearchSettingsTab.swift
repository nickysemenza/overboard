import OverboardMac
import SwiftUI

struct FileSearchSettingsTab: View {
    @State private var roots = ""
    @State private var exclusions = ""
    private let service = FileIndexService.shared

    var body: some View {
        Form {
            Section("Index") {
                LabeledContent("Status", value: self.service.status)
                if self.service.isIndexing { ProgressView().controlSize(.small) }
                ForEach(self.service.issues.prefix(6), id: \.self) { issue in
                    Text(issue).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section {
                TextEditor(text: self.$roots).font(.body.monospaced()).frame(height: 120)
                    .accessibilityLabel("Included folders, one path per line")
                Button("Use default locations") {
                    self.roots = FileIndexService.defaultRoots.map(\.path).joined(separator: "\n")
                }
            } header: { Text("Included folders") } footer: {
                Text("One folder path per line. Defaults include your home folder, iCloud Drive and Finder-visible cloud storage. Home excludes Library; cloud locations inside Library are included explicitly.")
            }
            Section {
                TextEditor(text: self.$exclusions).font(.body.monospaced()).frame(height: 110)
                    .accessibilityLabel("Excluded folder names or absolute paths, one per line")
            } header: { Text("Excluded folders") } footer: {
                Text("One folder name or absolute path per line. Hidden internals and app-package contents are skipped. Only names, paths, dates and cloud availability are indexed; file contents are never read.")
            }
            Button("Apply & Rebuild Index") {
                Defaults[.fileSearchRoots] = self.roots.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                Defaults[.fileSearchExclusions] = self.exclusions
                self.service.rebuild()
            }
        }
        .formStyle(.grouped)
        .onAppear {
            let saved = Defaults[.fileSearchRoots]
            self.roots = (saved.isEmpty ? FileIndexService.defaultRoots.map(\.path) : saved).joined(separator: "\n")
            self.exclusions = Defaults[.fileSearchExclusions]
        }
    }
}
