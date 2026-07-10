import AppKit
import MarkdownUI
import OverboardCore
import SwiftUI

/// Full-content preview (and inline editor) for the selected item, shown in
/// place of the card strip while the drawer panel is expanded.
struct PreviewPane: View {
    @Bindable var viewModel: DrawerViewModel
    @FocusState private var editorFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var fullText: String?
    @State private var highlightedCode: NSAttributedString?
    @State private var markdownSource: String?
    @State private var showRawMarkdown = false
    @State private var largeImage: NSImage?
    @State private var related: [ClipItem] = []

    private var item: ClipItem? {
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
            self.hints
        }
        .task(id: self.item?.id) {
            await self.load()
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
                    Label("Secret", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
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

    @ViewBuilder
    private var content: some View {
        if self.viewModel.previewState == .editing {
            TextEditor(text: self.$viewModel.editText)
                .font(.body)
                .focused(self.$editorFocused)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        } else if let item {
            switch item.kind {
            case .text, .link, .file:
                if let markdownSource, !self.showRawMarkdown {
                    ScrollView {
                        Markdown(markdownSource)
                            .markdownTheme(.basic)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                } else if let highlightedCode {
                    CodeTextView(attributed: highlightedCode)
                        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    ScrollView {
                        Text(self.fullText ?? item.previewText ?? "")
                            .font(item.kind == .file ? .body.monospaced() : .body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            case .image:
                if let largeImage {
                    Image(nsImage: largeImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .color:
                Image(systemName: "paintpalette.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.quaternary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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

    private var hints: some View {
        Text(self.viewModel.previewState == .editing
            ? "⌘↩ paste edited text   esc cancel"
            : "↩ paste   ⌘E edit   ←/→ browse   space or esc close")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func subtitle(for item: ClipItem) -> String {
        var parts: [String] = []
        if let app = item.sourceAppName { parts.append(app) }
        parts.append(item.lastUsedAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }

    private func load() async {
        self.fullText = nil
        self.highlightedCode = nil
        self.markdownSource = nil
        self.showRawMarkdown = false
        self.largeImage = nil
        self.related = []
        guard let item else { return }
        let store = self.viewModel.storeForCards

        switch item.kind {
        case .text, .link:
            let text = try? await store.plainText(for: item.id)
            self.fullText = text
            if let text, item.kind == .text, !item.isSecret {
                if item.category == "code" {
                    self.highlightedCode = CodeHighlighter.highlight(text, dark: self.colorScheme == .dark)
                } else if MarkdownDetector.looksLikeMarkdown(text) {
                    // Checked before looksLikeCode: a README's fenced block
                    // trips the code heuristic, and the clip would never
                    // render as markdown.
                    self.markdownSource = text
                } else if CodeHighlighter.looksLikeCode(text) {
                    self.highlightedCode = CodeHighlighter.highlight(text, dark: self.colorScheme == .dark)
                }
            }
        case .file:
            if let paths = try? await store.filePaths(for: item.id), !paths.isEmpty {
                self.fullText = paths.joined(separator: "\n")
            }
        case .image:
            if let rep = try? await store.representations(for: item.id)
                .first(where: { $0.uti == WellKnownUTI.png }),
                let data = try? await store.payload(for: rep)
            {
                self.largeImage = ItemCardView.thumbnail(from: data, maxPixel: 1600)
            }
        case .color:
            break
        }

        // Similar items by embedding proximity. Silent-fail to empty — the
        // strip simply doesn't render when there are no matches or no vector.
        self.related = await (try? store.relatedItems(to: item.id)) ?? []
    }
}
