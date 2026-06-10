import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Edits a newline-joined list of bundle IDs (the storage format stays
/// hand-editable via `defaults`) as proper app rows with icons and names,
/// plus an NSOpenPanel picker for adding apps.
struct AppListEditor: View {
    @Binding var rawList: String

    private var bundleIDs: [String] {
        self.rawList
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if self.bundleIDs.isEmpty {
                Text("No apps")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }
            ForEach(self.bundleIDs, id: \.self) { bundleID in
                self.row(for: bundleID)
                if bundleID != self.bundleIDs.last {
                    Divider()
                }
            }
            Divider()
            HStack {
                Button {
                    self.pickApps()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add an application")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 6)
        }
    }

    private func row(for bundleID: String) -> some View {
        HStack(spacing: 8) {
            if let icon = AppIconCache.shared.icon(forBundleID: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "questionmark.app.dashed")
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.displayName(for: bundleID) ?? bundleID)
                if Self.displayName(for: bundleID) != nil {
                    Text(bundleID)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                self.remove(bundleID)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
        .padding(.vertical, 5)
    }

    private static func displayName(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    private func pickApps() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose applications to add"
        guard panel.runModal() == .OK else { return }

        var ids = self.bundleIDs
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier,
                  !ids.contains(bundleID)
            else { continue }
            ids.append(bundleID)
        }
        self.rawList = ids.sorted().joined(separator: "\n")
    }

    private func remove(_ bundleID: String) {
        self.rawList = self.bundleIDs
            .filter { $0 != bundleID }
            .joined(separator: "\n")
    }
}
