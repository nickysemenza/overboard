import AppKit
import MarkdownUI
import SwiftUI

@MainActor
public struct FilePreviewView: View {
    public let content: FilePreviewContent
    @Environment(\.colorScheme) private var colorScheme
    @State private var highlighted: NSAttributedString?

    public init(content: FilePreviewContent) {
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if self.content.isMarkdown {
                ScrollView {
                    Markdown(self.content.text)
                        .markdownTheme(.basic)
                        .markdownCodeSyntaxHighlighter(HighlightrMarkdownSyntaxHighlighter(dark: self.colorScheme == .dark))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else if let highlighted {
                FilePreviewTextView(attributed: highlighted)
            } else {
                ScrollView {
                    Text(self.content.text)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
            if self.content.isTruncated {
                Label("Preview truncated to keep Quick Look responsive", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .task(id: "\(self.content.url.path)-\(self.colorScheme == .dark)") {
            guard !self.content.isMarkdown else { self.highlighted = nil; return }
            let highlighted = await HighlightrCache.shared.highlight(self.content.text, language: self.content.language, dark: self.colorScheme == .dark)
            guard !Task.isCancelled else { return }
            self.highlighted = highlighted
        }
    }
}

@MainActor
private struct HighlightrMarkdownSyntaxHighlighter: CodeSyntaxHighlighter {
    let dark: Bool

    func highlightCode(_ code: String, language: String?) -> Text {
        guard let highlighted = HighlightrCache.shared.highlightSync(code, language: language, dark: self.dark),
              let attributed = try? AttributedString(highlighted, including: \.appKit)
        else { return Text(code) }
        return Text(attributed)
    }
}

private struct FilePreviewTextView: NSViewRepresentable {
    let attributed: NSAttributedString

    func makeNSView(context _: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context _: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.textStorage?.setAttributedString(self.attributed)
    }
}
