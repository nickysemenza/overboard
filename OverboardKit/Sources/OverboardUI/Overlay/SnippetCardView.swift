import OverboardCore
import SwiftUI

struct SnippetCardView: View {
    let snippet: Snippet
    let index: Int
    let isSelected: Bool
    /// Matches ItemCardView so the two card kinds stay the same size in a
    /// strip that mixes them. `cardShell` owns the matching width metric.
    @ScaledMetric(relativeTo: .callout) private var cardHeight: CGFloat = CardMetrics.height

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header
            Divider().opacity(0.4)
            Text(self.snippet.body)
                .font(.callout)
                .lineLimit(self.bodyLineLimit)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .cardShell(isSelected: self.isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.accessibilityCardLabel)
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
    }

    /// VoiceOver summary for the whole card: title plus a short body preview,
    /// so the card reads as one item instead of its individual subviews.
    private var accessibilityCardLabel: String {
        let preview = self.snippet.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preview.isEmpty else { return self.snippet.title }
        return "\(self.snippet.title), \(preview)"
    }

    /// The card grows with Dynamic Type but not as fast as the type does, so
    /// the line budget shrinks to keep the body inside the card.
    private var bodyLineLimit: Int {
        max(1, Int((7 * CardMetrics.height / self.cardHeight).rounded(.down)))
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
                    .contrastAwareForeground(.tertiary)
                    .accessibilityLabel("Command \(self.index + 1)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.background.opacity(0.5))
    }
}

#if DEBUG
    #Preview("Light") {
        let snippet = Snippet(
            title: "Standup update",
            body: "Yesterday: shipped X.\nToday: working on Y.\nBlockers: none."
        )
        SnippetCardView(snippet: snippet, index: 0, isSelected: false)
            .padding()
    }

    #Preview("Selected") {
        let snippet = Snippet(
            title: "Standup update",
            body: "Yesterday: shipped X.\nToday: working on Y.\nBlockers: none."
        )
        SnippetCardView(snippet: snippet, index: 0, isSelected: true)
            .padding()
    }
#endif
