import OverboardCore
import SwiftUI

// MARK: - Content loading

extension PreviewPane {
    func load() async {
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
            guard await self.loadTextOrLink(item, store: store) else { return }
        case .file:
            await self.loadFile(item, store: store)
        case .image:
            await self.loadImage(item, store: store)
        case .color:
            break
        }

        // Similar items by embedding proximity. Silent-fail to empty — the
        // strip simply doesn't render when there are no matches or no vector.
        self.related = await (try? store.relatedItems(to: item.id)) ?? []
    }

    /// Loads plain text and, for non-secret text clips, code-highlights or
    /// markdown-renders it. Returns `false` if the highlighting task was
    /// cancelled mid-flight (a newer `.task(id:)` superseded this one), in
    /// which case the caller skips fetching related items for an already-stale
    /// load.
    private func loadTextOrLink(_ item: ClipItem, store: ClipStore) async -> Bool {
        let text = try? await store.plainText(for: item.id)
        self.fullText = text
        guard let text, item.kind == .text, !item.isSecret else { return true }
        if item.category == "code" {
            return await self.highlightCode(text)
        } else if MarkdownDetector.looksLikeMarkdown(text) {
            // Checked before looksLikeCode: a README's fenced block trips the
            // code heuristic, and the clip would never render as markdown.
            self.markdownSource = text
        } else if CodeHighlighter.looksLikeCode(text) {
            return await self.highlightCode(text)
        }
        return true
    }

    /// Highlights `text` and stores the result, unless cancelled mid-flight.
    private func highlightCode(_ text: String) async -> Bool {
        let highlighted = await CodeHighlighter.highlight(text, dark: self.colorScheme == .dark)
        guard !Task.isCancelled else { return false }
        self.highlightedCode = highlighted
        return true
    }

    private func loadFile(_ item: ClipItem, store: ClipStore) async {
        if let paths = try? await store.filePaths(for: item.id), !paths.isEmpty {
            self.fullText = paths.joined(separator: "\n")
        }
    }

    private func loadImage(_ item: ClipItem, store: ClipStore) async {
        if let rep = try? await store.representations(for: item.id)
            .first(where: { $0.uti == WellKnownUTI.png }),
            let data = try? await store.payload(for: rep)
        {
            self.largeImage = ItemCardView.thumbnail(from: data, maxPixel: 1600)
        }
    }
}
