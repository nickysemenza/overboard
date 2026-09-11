import SwiftUI

/// Cards ripple up into place when the drawer is summoned. The delay caps so
/// cards lazily appearing mid-scroll don't lag behind the scroll.
struct CardEntrance: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(self.shown ? 1 : 0)
            .offset(y: self.shown ? 0 : 26)
            .onAppear {
                if self.reduceMotion { self.shown = true; return }
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
    /// shape inside a `GlassEffectContainer` so Liquid Glass can morph between
    /// adjacent shapes. Floating menus use their own opaque surface: overlapping
    /// glass shapes merge behind the host content. Leave both nil for standalone glass.
    func glassPanel(cornerRadius: CGFloat, id: String? = nil, in namespace: Namespace.ID? = nil) -> some View {
        modifier(AccessibleGlassPanel(cornerRadius: cornerRadius, id: id, namespace: namespace))
    }
}

private struct AccessibleGlassPanel: ViewModifier {
    let cornerRadius: CGFloat
    let id: String?
    let namespace: Namespace.ID?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        Group {
            if self.reduceTransparency {
                content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: self.cornerRadius))
            } else if let id, let namespace {
                content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: self.cornerRadius)).glassEffectID(id, in: namespace)
            } else {
                content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: self.cornerRadius))
            }
        }
        .transaction { if self.reduceMotion { $0.animation = nil } }
    }
}

/// The empty-state boat bobs gently on the (invisible) waves.
struct BobbingBoat: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if self.reduceMotion {
            Image(systemName: "sailboat").font(.largeTitle).foregroundStyle(.secondary)
        } else {
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
