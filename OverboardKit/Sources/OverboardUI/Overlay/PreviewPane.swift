import AppKit
import OverboardCore
import SwiftUI

/// Full-content preview (and inline editor) for the selected item, shown in
/// place of the card strip while the drawer panel is expanded.
struct PreviewPane: View {
    @Bindable var viewModel: DrawerViewModel
    /// `internal`: read/set from `content` in PreviewPane+Content.swift.
    @FocusState var editorFocused: Bool
    /// `internal`: read from `load()` in PreviewPane+Loading.swift.
    @Environment(\.colorScheme) var colorScheme
    /// `internal`: read from PreviewPane+Content.swift, set from
    /// PreviewPane+Loading.swift.
    @State var fullText: String?
    @State var highlightedCode: NSAttributedString?
    @State var markdownSource: String?
    @State var showRawMarkdown = false
    @State var largeImage: NSImage?
    /// `internal`: set from `load()` in PreviewPane+Loading.swift.
    @State var related: [ClipItem] = []

    /// `internal`: read from PreviewPane+Content.swift and
    /// PreviewPane+Loading.swift.
    var item: ClipItem? {
        self.viewModel.selectedItem
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            self.header
            if let item, let source = item.sourceURL, !source.isEmpty {
                self.provenanceRow(source: source, title: item.sourceTitle)
            }
            self.content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if !self.related.isEmpty {
                self.relatedStrip
            }
        }
        .task(id: self.item?.id) {
            await self.load()
        }
        .onChange(of: self.colorScheme) {
            guard self.highlightedCode != nil, let text = self.fullText else { return }
            Task { self.highlightedCode = await CodeHighlighter.highlight(text, dark: self.colorScheme == .dark) }
        }
        .onChange(of: self.viewModel.previewState) {
            self.editorFocused = self.viewModel.previewState == .editing
        }
        .onAppear {
            self.editorFocused = self.viewModel.previewState == .editing
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let item {
                if let icon = AppIconCache.shared.icon(forBundleID: item.sourceBundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.aiTitle ?? item.previewText ?? "Clip")
                        .font(.headline)
                        .lineLimit(1)
                    Text(self.subtitle(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if item.isSecret {
                    SecretBadge()
                }
                if self.markdownSource != nil {
                    Button {
                        self.showRawMarkdown.toggle()
                    } label: {
                        Image(systemName: self.showRawMarkdown ? "doc.richtext" : "text.alignleft")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(self.showRawMarkdown ? "Show rendered markdown" : "Show raw markdown")
                    .accessibilityLabel(self.showRawMarkdown ? "Show rendered markdown" : "Show raw markdown")
                }
                if self.viewModel.previewState == .editing {
                    Text("Editing")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
            }
        }
    }

    /// Back-to-source provenance: a clickable row linking to the browser page
    /// this clip was copied from. Shows the page title when known, else the URL
    /// host. Opens the source in the default browser via NSWorkspace.
    private func provenanceRow(source: String, title: String?) -> some View {
        let label = (title?.isEmpty == false ? title : nil)
            ?? ClipItem.linkHost(fromPreview: source)
            ?? source
        return Button {
            if let url = URL(string: source) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .accessibilityHidden(true)
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Open source page — \(source)")
    }

    private var relatedStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Related")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(self.related.prefix(5)) { related in
                    self.relatedChip(related)
                }
            }
        }
    }

    private func relatedChip(_ related: ClipItem) -> some View {
        Button {
            self.viewModel.jump(toItemID: related.id)
        } label: {
            HStack(spacing: 6) {
                if let icon = AppIconCache.shared.icon(forBundleID: related.sourceBundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                Text(related.aiTitle ?? related.previewText ?? "Clip")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 140, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(related.aiTitle ?? related.previewText ?? "Clip")
    }

    private func subtitle(for item: ClipItem) -> String {
        var parts: [String] = []
        if let app = item.sourceAppName {
            parts.append(app)
        }
        parts.append(TimestampFormatter.absolute(item.lastUsedAt))
        return parts.joined(separator: " · ")
    }
}

#if DEBUG
    #Preview("Viewing") {
        SeededPreview { store in
            PreviewPaneDemo(store: store, editing: false)
        }
        // Matches OverlayController's expanded panel frame (full screen width,
        // while previewing); a fixed 900pt stands in for the screen
        // width in previews.
        .frame(width: 900, height: CardMetrics.expandedPanelHeight)
    }

    #Preview("Editing") {
        SeededPreview { store in
            PreviewPaneDemo(store: store, editing: true)
        }
        .frame(width: 900, height: CardMetrics.expandedPanelHeight)
    }

    /// Waits for the seeded store's initial search to land, selects the plain-text
    /// fixture item, then opens the preview pane (optionally straight into edit
    /// mode) — `PreviewPane` only renders item content once
    /// `viewModel.selectedItem` is non-nil.
    private struct PreviewPaneDemo: View {
        let store: ClipStore
        let editing: Bool
        @State private var viewModel: DrawerViewModel?

        var body: some View {
            Group {
                if let viewModel {
                    PreviewPane(viewModel: viewModel)
                } else {
                    ProgressView()
                }
            }
            .task {
                let model = Fixtures.drawerViewModel(store: self.store)
                for _ in 0 ..< 2000 where model.items.isEmpty {
                    await Task.yield()
                }
                if let index = model.items
                    .firstIndex(where: { $0.previewText?.contains("Pick up the package") == true })
                {
                    model.selectedIndex = index
                }
                if self.editing {
                    model.beginEdit()
                } else {
                    model.togglePreview()
                }
                self.viewModel = model
            }
        }
    }
#endif
