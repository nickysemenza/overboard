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
