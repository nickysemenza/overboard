import SwiftUI

/// Section label above a run of rows or cells ("Apps", "Recent searches",
/// "Smileys & Emotion"). DESIGN.md § Typography makes the launcher's inline
/// style canonical: `.caption.weight(.semibold)`, secondary, sentence case —
/// *not* the uppercase tertiary variant the emoji picker used to carry.
struct PanelSectionHeader: View {
    let title: String

    var body: some View {
        Text(self.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }
}

#if DEBUG
    #Preview("Section header") {
        VStack(alignment: .leading, spacing: 0) {
            PanelSectionHeader(title: "Apps")
            PanelSectionHeader(title: "Recent searches")
        }
        .padding()
        .frame(width: 300)
    }
#endif
