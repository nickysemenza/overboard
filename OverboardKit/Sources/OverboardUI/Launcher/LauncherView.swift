import AppKit
import OverboardCore
import SwiftUI
import UniformTypeIdentifiers

public struct LauncherView: View {
    @Bindable var viewModel: LauncherViewModel
    @FocusState private var fieldFocused: Bool

    public init(viewModel: LauncherViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 8) {
            self.searchBar
            if !self.viewModel.results.isEmpty {
                Divider()
                VStack(spacing: 2) {
                    ForEach(Array(self.viewModel.results.enumerated()), id: \.element.id) { index, result in
                        LauncherRow(result: result, isSelected: index == self.viewModel.selectedIndex)
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                            .onTapGesture {
                                self.viewModel.selectedIndex = index
                                self.viewModel.commit()
                            }
                    }
                }
            }
        }
        .padding(14)
        .glassPanel(cornerRadius: 16)
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .padding(12)
        .onAppear {
            self.fieldFocused = true
        }
        .onChange(of: self.viewModel.showGeneration) {
            self.fieldFocused = true
        }
        .onChange(of: self.viewModel.query) {
            self.viewModel.scheduleSearch()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(.secondary)
            TextField("Calculate, search clips, files, the web…", text: self.$viewModel.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused(self.$fieldFocused)
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
    }
}

struct LauncherRow: View {
    let result: LauncherResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            self.icon
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(self.title)
                    .font(.body.weight(self.titleWeight))
                    .lineLimit(1)
                Text(self.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if self.isSelected {
                Text(self.shortcutHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            self.isSelected ? Color.accentColor.opacity(0.22) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    @ViewBuilder private var icon: some View {
        switch self.result {
        case .calculation:
            Image(systemName: "equal.circle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
        case let .app(_, url), let .file(_, url):
            Image(nsImage: Self.fileIcon(for: url))
                .resizable()
                .aspectRatio(contentMode: .fit)
        case .snippet:
            Image(systemName: "text.badge.star")
                .font(.title2)
                .foregroundStyle(.purple)
        case let .clip(item):
            if let appIcon = AppIconCache.shared.icon(forBundleID: item.sourceBundleID) {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: Self.kindSymbol(for: item.kind))
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        case .webSearch:
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.title2)
                .foregroundStyle(.blue)
        }
    }

    private var title: String {
        switch self.result {
        case let .calculation(_, display): display
        case let .app(name, _): name
        case let .snippet(snippet): snippet.title
        case let .clip(item): Self.clipTitle(for: item)
        case let .file(name, _): name
        case let .webSearch(query, _): "Search Google for “\(query)”"
        }
    }

    private var titleWeight: Font.Weight {
        if case .calculation = self.result { .semibold } else { .regular }
    }

    private var subtitle: String {
        switch self.result {
        case let .calculation(input, _): "\(input.trimmingCharacters(in: .whitespaces)) ="
        case .app: "Application"
        case let .snippet(snippet): Self.firstLine(of: snippet.body) ?? "Snippet"
        case let .clip(item): Self.clipSubtitle(for: item)
        case let .file(_, url): (url.path as NSString).abbreviatingWithTildeInPath
        case .webSearch: "Open in browser"
        }
    }

    /// Missing paths (demo mode's fake files) get their file-type icon
    /// instead of the blank generic-document one.
    private static func fileIcon(for url: URL) -> NSImage {
        if FileManager.default.fileExists(atPath: url.path) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    private var shortcutHint: String {
        switch self.result {
        case .calculation: "↩ copy   ⌘↩ paste"
        case .app: "↩ open   ⌘↩ reveal   ⌥↩ copy path"
        case .snippet: "↩ paste   ⌘↩ copy"
        case .clip: "↩ paste   ⌘↩ copy   ⌥↩ paste plain"
        case .file: "↩ open   ⌘↩ reveal   ⌥↩ copy path"
        case .webSearch: "↩ search"
        }
    }

    // MARK: - Clip row helpers

    private static func clipTitle(for item: ClipItem) -> String {
        item.aiTitle
            ?? self.firstLine(of: item.previewText ?? "")
            ?? self.kindLabel(for: item.kind)
    }

    private static func clipSubtitle(for item: ClipItem) -> String {
        let when = item.lastUsedAt.formatted(.relative(presentation: .named))
        guard let app = item.sourceAppName else { return when }
        return "\(app) · \(when)"
    }

    private static func firstLine(of text: String) -> String? {
        let line = text
            .split(whereSeparator: \.isNewline)
            .first?
            .trimmingCharacters(in: .whitespaces)
        return (line?.isEmpty ?? true) ? nil : line
    }

    private static func kindSymbol(for kind: ItemKind) -> String {
        switch kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        case .color: "paintpalette"
        }
    }

    private static func kindLabel(for kind: ItemKind) -> String {
        switch kind {
        case .text: "Text"
        case .link: "Link"
        case .image: "Image"
        case .file: "File"
        case .color: "Color"
        }
    }
}
