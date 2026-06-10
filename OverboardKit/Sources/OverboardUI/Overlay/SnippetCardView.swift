import OverboardCore
import SwiftUI

struct SnippetCardView: View {
    let snippet: Snippet
    let index: Int
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header
            Divider().opacity(0.4)
            Text(self.snippet.body)
                .font(.callout)
                .lineLimit(7)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 190, height: 180)
        .background(.background.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    self.isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                    lineWidth: self.isSelected ? 2.5 : 1
                )
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.badge.star")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(self.snippet.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Spacer()
            if self.index < 9 {
                Text("⌘\(self.index + 1)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.background.opacity(0.5))
    }
}
