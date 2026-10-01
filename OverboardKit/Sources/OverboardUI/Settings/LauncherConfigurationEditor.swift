import Defaults
import OverboardCore
import OverboardMac
import SwiftUI

struct LauncherConfigurationEditor: View {
    @Binding var appliedText: String
    let kind: LauncherConfigurationKind
    @State private var draft = ""
    @State private var advanced = false
    @State private var previewInput = "example search"
    @State private var previewUsesClipboard = false
    @State private var loaded = false

    private var draftKey: Defaults.Key<String?> {
        Defaults.Key("launcher.\(self.kind.rawValue).draft", default: nil, suite: AppPreferenceStorage.suite)
    }

    private var configuration: LauncherConfigurationDraft {
        .init(text: self.draft, kind: self.kind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Advanced text", isOn: self.$advanced)
                .toggleStyle(.switch)
                .controlSize(.small)
            if self.advanced {
                SettingsTextListEditor(
                    text: self.$draft, height: 110,
                    accessibilityLabel: self.kind == .aliases ? "App aliases draft" : "Quicklinks draft"
                )
            } else {
                ForEach(self.configuration.entries) { entry in
                    self.row(entry)
                }
                if !self.configuration.issues.isEmpty {
                    Text("Open Advanced text to repair malformed lines. Your draft is kept.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Add \(self.kind == .aliases ? "alias" : "quicklink")") {
                    let keyword = self.nextKeyword
                    let destination = self.kind == .aliases ? "App Name" : "https://example.com/?q={query}"
                    self.draft += (self.draft.isEmpty || self.draft.hasSuffix("\n") ? "" : "\n")
                        + "\(keyword) = \(destination)"
                }
            }
            ForEach(self.configuration.issues) { issue in
                Label("Line \(issue.line + 1): \(issue.message)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            if self.kind == .quicklinks {
                Toggle("Preview with sample clipboard input", isOn: self.$previewUsesClipboard)
                    .controlSize(.small)
                TextField("Preview input (not your clipboard)", text: self.$previewInput)
                    .textFieldStyle(.roundedBorder)
                ForEach(self.configuration.entries) { entry in
                    if let destination = self.destinationPreview(entry) {
                        let kind = destination.kind == .application ? "Launch application" : "Open web page"
                        Text("\(entry.keyword): \(kind) → \(destination.url.absoluteString)")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    } else if entry.destination.contains("{clipboard}"), !self.previewUsesClipboard,
                              !self.configuration.issues.contains(where: { $0.line == entry.line })
                    {
                        Text("\(entry.keyword): Choose sample clipboard input to preview this destination.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Apply") {
                    self.appliedText = self.draft
                    Defaults[self.draftKey] = nil
                }
                .disabled(!self.loaded || !self.configuration.issues.isEmpty || self.draft == self.appliedText)
                Button("Discard draft") {
                    self.draft = self.appliedText
                    Defaults[self.draftKey] = nil
                }
                .disabled(self.draft == self.appliedText)
                if self.draft != self.appliedText {
                    Text("Unsaved draft").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task {
            guard !self.loaded else { return }
            self.draft = Defaults[self.draftKey] ?? self.appliedText
            self.advanced = !self.configuration.issues.isEmpty
            self.loaded = true
        }
        .onChange(of: self.draft) {
            guard self.loaded else { return }
            Defaults[self.draftKey] = self.draft == self.appliedText ? nil : self.draft
        }
    }

    private var nextKeyword: String {
        let keywords = Set(self.configuration.entries.map { AppMatcher.fold($0.keyword) })
        var index = 1
        while keywords.contains("new\(index)") {
            index += 1
        }
        return "new\(index)"
    }

    private func row(_ entry: LauncherConfigurationEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Keyword", text: self.binding(entry, field: \.keyword))
                    .frame(maxWidth: 110)
                if self.kind == .quicklinks {
                    TextField("Display name (optional)", text: self.binding(entry, field: \.name))
                }
                Button("Remove", systemImage: "minus.circle") {
                    self.draft = self.configuration.removing(line: entry.line)
                }
                .labelStyle(.iconOnly).help("Remove \(entry.keyword)")
                .accessibilityLabel("Remove \(entry.keyword)")
            }
            TextField(
                self.kind == .aliases ? "App name" : "Destination URL template",
                text: self.binding(entry, field: \.destination)
            )
        }
        .textFieldStyle(.roundedBorder)
    }

    private func binding(
        _ entry: LauncherConfigurationEntry, field: WritableKeyPath<LauncherConfigurationEntry, String>
    ) -> Binding<String> {
        Binding {
            self.configuration.entries.first(where: { $0.line == entry.line })?[keyPath: field] ?? ""
        } set: { value in
            guard var current = self.configuration.entries.first(where: { $0.line == entry.line }) else { return }
            current[keyPath: field] = value
            self.draft = self.configuration.replacing(current)
        }
    }

    private func destinationPreview(_ entry: LauncherConfigurationEntry) -> Quicklink.Destination? {
        guard !self.configuration.issues.contains(where: { $0.line == entry.line }) else { return nil }
        let link = Quicklink(keyword: entry.keyword, name: entry.name, template: entry.destination)
        return link
            .destination(for: self.previewUsesClipboard ? .clipboard(self.previewInput) : .query(self.previewInput))
    }
}
