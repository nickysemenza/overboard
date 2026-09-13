import SwiftUI

/// The query field every summonable surface opens with: a leading symbol, a
/// plain native text field (DESIGN.md § Inputs: "without a second enclosing
/// input box"), and whatever trailing accessories the host needs.
///
/// The launcher is the one surface that reads as a *primary* search box, so it
/// keeps its taller frame and larger type through `size: .large`; the drawer
/// and emoji picker use `.regular`.
struct PanelSearchField<Accessory: View>: View {
    enum Size {
        case large
        case regular
    }

    let symbol: String
    let prompt: String
    @Binding var text: String
    var size: Size = .regular
    var accessibilityLabel: String?
    let focus: FocusState<Bool>.Binding
    @ViewBuilder var accessory: () -> Accessory

    /// The launcher query's 20pt face predates semantic roles and sits between
    /// `.title2` and `.title`; a metric relative to `.title2` keeps the type
    /// scaling with Dynamic Type without resizing the panel's search bar today.
    @ScaledMetric(relativeTo: .title2) private var largeFontSize: CGFloat = 20
    @ScaledMetric(relativeTo: .title2) private var largeFieldHeight: CGFloat = 62

    var body: some View {
        HStack(spacing: self.size == .large ? 12 : 8) {
            Image(systemName: self.symbol)
                .font(self.size == .large ? .title3 : nil)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(self.prompt, text: self.$text)
                .textFieldStyle(.plain)
                .font(self.size == .large ? .system(size: self.largeFontSize) : .title3)
                .focused(self.focus)
                .accessibilityLabel(self.accessibilityLabel ?? self.prompt)
            self.accessory()
        }
        .padding(.horizontal, self.size == .large ? 20 : 6)
        .frame(height: self.size == .large ? self.largeFieldHeight : nil)
    }
}

extension PanelSearchField where Accessory == EmptyView {
    init(
        symbol: String,
        prompt: String,
        text: Binding<String>,
        size: Size = .regular,
        accessibilityLabel: String? = nil,
        focus: FocusState<Bool>.Binding
    ) {
        self.init(
            symbol: symbol,
            prompt: prompt,
            text: text,
            size: size,
            accessibilityLabel: accessibilityLabel,
            focus: focus,
            accessory: { EmptyView() }
        )
    }
}

#if DEBUG
    private struct PanelSearchFieldPreview: View {
        var size: PanelSearchField<EmptyView>.Size
        @State private var text = ""
        @FocusState private var focused: Bool

        var body: some View {
            PanelSearchField(
                symbol: "magnifyingglass",
                prompt: "Search apps, files, clipboard, or the web…",
                text: self.$text,
                size: self.size,
                focus: self.$focused
            )
        }
    }

    #Preview("Large") {
        PanelSearchFieldPreview(size: .large).frame(width: 480)
    }

    #Preview("Regular") {
        PanelSearchFieldPreview(size: .regular).frame(width: 480).padding()
    }
#endif
