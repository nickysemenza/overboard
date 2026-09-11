import SwiftUI

/// Cards ripple up into place when the drawer is summoned. The delay caps so
/// cards lazily appearing mid-scroll don't lag behind the scroll.
struct CardEntrance: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(self.shown ? 1 : 0)
            .offset(y: self.shown ? 0 : 26)
            .onAppear {
                withAnimation(
                    .spring(response: 0.36, dampingFraction: 0.8)
                        .delay(Double(min(self.index, 8)) * 0.028)
                ) {
                    self.shown = true
                }
            }
    }
}

extension View {
    func cardEntrance(index: Int) -> some View {
        modifier(CardEntrance(index: index))
    }

    /// Liquid Glass panel chrome shared by every summonable surface.
    ///
    /// Pass `id` + `namespace` when this shape sits alongside a sibling glass
    /// shape inside a `GlassEffectContainer` (e.g. a panel and the ⌘K palette that
    /// pops out of it) so Liquid Glass morphs between them instead of just
    /// cross-fading. Leave both nil for a standalone glass shape.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat, id: String? = nil, in namespace: Namespace.ID? = nil) -> some View {
        if let id, let namespace {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
                .glassEffectID(id, in: namespace)
        } else {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

/// The empty-state boat bobs gently on the (invisible) waves.
struct BobbingBoat: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Image(systemName: "sailboat")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .offset(y: sin(t * 1.6) * 3)
                .rotationEffect(.degrees(sin(t * 1.1) * 4))
        }
    }
}

#if DEBUG
    #Preview("Bobbing boat") {
        BobbingBoat()
            .padding(40)
    }

    #Preview("Card entrance") {
        let item = Fixtures.item(preview: "Cards ripple up into place when the drawer is summoned.")
        ItemCardView(item: item, index: 0, isSelected: false, store: try! Fixtures.store())
            .cardEntrance(index: 0)
            .padding()
    }
#endif
