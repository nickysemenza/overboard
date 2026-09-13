import MarkdownUI
import OverboardCore
import SwiftUI

// MARK: - Per-kind preview content

extension PreviewPane {
    @ViewBuilder
    var content: some View {
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
                    .scrollEdgeEffectStyle(.soft, for: .top)
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
                    .scrollEdgeEffectStyle(.soft, for: .top)
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
                    .contrastAwareForeground(.quaternary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
