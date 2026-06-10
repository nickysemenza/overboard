import AppKit
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
    @State private var largeImage: NSImage?

    private var item: ClipItem? {
        self.viewModel.selectedItem
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            self.header
            self.content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                if let highlightedCode {
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
        self.largeImage = nil
        guard let item else { return }
        let store = self.viewModel.storeForCards

        switch item.kind {
        case .text, .link:
            let text = try? await store.plainText(for: item.id)
            self.fullText = text
            if let text, item.kind == .text, !item.isSecret,
               item.category == "code" || CodeHighlighter.looksLikeCode(text)
            {
                self.highlightedCode = CodeHighlighter.highlight(text, dark: self.colorScheme == .dark)
            }
        case .file:
            if let rep = try? await store.representations(for: item.id)
                .first(where: { $0.uti == WellKnownUTI.fileURLs }),
                let data = try? await store.payload(for: rep),
                let urlStrings = try? JSONDecoder().decode([String].self, from: data)
            {
                self.fullText = urlStrings
                    .compactMap { URL(string: $0)?.path }
                    .joined(separator: "\n")
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
    }
}
