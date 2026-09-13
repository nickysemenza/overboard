// Shared chrome helpers: the motion, material, contrast, and geometry
// primitives every summonable surface draws itself with. The panel *components*
// built on top of them live in `Chrome/`.

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
                if self.reduceMotion {
                    self.shown = true; return
                }
                withAnimation(
                    .spring(response: 0.36, dampingFraction: 0.8)
                        .delay(Double(min(self.index, 8)) * 0.028)
                ) {
                    self.shown = true
                }
            }
    }
}

/// Corner radii for the summonable panel shells (DESIGN.md § Shapes: "Larger
/// shells retain their component-specific shapes").
enum PanelRadius {
    static let launcher: CGFloat = 18
    static let drawer: CGFloat = 16
    static let palette: CGFloat = 12
}

/// Clipboard/snippet card geometry, and the drawer panel heights derived from
/// it. Card size, strip height, and panel height used to be four unrelated
/// literals (190/180, 184, 282, 540) that had to be kept in step by hand.
enum CardMetrics {
    /// DESIGN.md frontmatter `components.clipboard-card`.
    static let width: CGFloat = 190
    static let height: CGFloat = 180

    /// The card strip's 2pt vertical breathing room on each side.
    private static let stripPadding: CGFloat = 2

    /// Everything in the collapsed drawer that isn't the card strip: the panel
    /// padding, the search bar, the footer hints, and the stack spacing.
    private static let drawerChrome: CGFloat = 98

    /// Height of the horizontal card strip for a (possibly scaled) card.
    static func stripHeight(cardHeight: CGFloat = height) -> CGFloat {
        cardHeight + self.stripPadding * 2
    }

    /// Collapsed overlay-panel height. Derived from the *unscaled* card: macOS
    /// has no system-wide Dynamic Type control, so `@ScaledMetric` only moves
    /// when a view explicitly overrides `dynamicTypeSize` (previews, snapshot
    /// tests) — and `OverlayController` sizes the panel from AppKit, outside any
    /// SwiftUI environment that could carry an override.
    static let collapsedPanelHeight: CGFloat = stripHeight() + drawerChrome

    /// Expanded height while the preview pane is showing.
    static let expandedPanelHeight: CGFloat = 540
}

extension View {
    func cardEntrance(index: Int) -> some View {
        modifier(CardEntrance(index: index))
    }

    /// Applies `animation` to changes in `value`, unless Reduce Motion is
    /// enabled — in which case the change lands instantly, same as passing
    /// `nil` to `.animation(_:value:)` directly. Centralizes that check so
    /// call sites (selection tint, card hover) don't each read
    /// `accessibilityReduceMotion` themselves.
    func motion(_ animation: Animation, value: some Equatable) -> some View {
        modifier(ReducedMotionAnimation(animation: animation, value: value))
    }

    /// Foreground for the quietest supporting text — keycaps, counts, footers,
    /// placeholder glyphs. Under Increase Contrast the requested tertiary or
    /// quaternary level is promoted to `.secondary`, because at those levels
    /// macOS's own contrast boost can't rescue the text. Centralizes the check
    /// so the ~18 call sites don't each read `colorSchemeContrast`.
    func contrastAwareForeground(_ style: HierarchicalShapeStyle) -> some View {
        modifier(ContrastAwareForeground(style: style))
    }

    /// Liquid Glass panel chrome shared by every summonable surface.
    ///
    /// Pass `id` + `namespace` when this shape sits alongside a sibling glass
    /// shape inside a `GlassEffectContainer` so Liquid Glass can morph between
    /// adjacent shapes. Floating menus use their own opaque surface: overlapping
    /// glass shapes merge behind the host content. Leave both nil for standalone glass.
    func glassPanel(cornerRadius: CGFloat, id: String? = nil, in namespace: Namespace.ID? = nil) -> some View {
        modifier(AccessibleGlassPanel(
            shape: RoundedRectangle(cornerRadius: cornerRadius),
            id: id,
            namespace: namespace
        ))
    }

    /// Same shared glass chrome, for shells that aren't a rounded rectangle
    /// (the HUD's capsule).
    func glassPanel(shape: some Shape, id: String? = nil, in namespace: Namespace.ID? = nil) -> some View {
        modifier(AccessibleGlassPanel(shape: shape, id: id, namespace: namespace))
    }
}

private struct ContrastAwareForeground: ViewModifier {
    let style: HierarchicalShapeStyle
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.foregroundStyle(self.contrast == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(self.style))
    }
}

private struct ReducedMotionAnimation<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(self.reduceMotion ? nil : self.animation, value: self.value)
    }
}

/// Button chrome for the launcher's selectable rows: a selected tint
/// (`Color.accentColor.opacity(0.20)` per DESIGN.md), a quiet hover tint, and a
/// slightly stronger pressed tint. The tint lives in a nested `RowBody` view
/// (rather than reading `configuration.isPressed` straight in `makeBody`)
/// because that's what lets the style track hover state — `ButtonStyle`
/// itself can't hold `@State`.
struct LauncherRowButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, isSelected: self.isSelected)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        @State private var isHovering = false

        var body: some View {
            self.configuration.label
                .background(self.fill, in: RoundedRectangle(cornerRadius: 8))
                .onHover { self.isHovering = $0 }
                .motion(.snappy(duration: 0.12), value: self.isSelected)
        }

        private var fill: Color {
            if self.isSelected {
                return self.configuration.isPressed ? Color.accentColor.opacity(0.28) : Color.accentColor.opacity(0.20)
            }
            if self.configuration.isPressed {
                return Color.primary.opacity(0.10)
            }
            if self.isHovering {
                return Color.primary.opacity(0.06)
            }
            return .clear
        }
    }
}

extension EnvironmentValues {
    /// Forces `.glassPanel` onto the flat `windowBackgroundColor` fallback
    /// that Reduce Transparency also selects. Snapshot tests set it: Liquid
    /// Glass is GPU-composited and doesn't survive an offscreen `cacheDisplay`
    /// on a CI VM, whereas the flat chrome renders identically everywhere.
    /// (`accessibilityReduceTransparency` itself is get-only.)
    @Entry var flattensGlassPanels = false
}

private struct AccessibleGlassPanel<S: Shape>: ViewModifier {
    let shape: S
    let id: String?
    let namespace: Namespace.ID?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.flattensGlassPanels) private var flattensGlassPanels
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        Group {
            if self.reduceTransparency || self.flattensGlassPanels {
                content.background(Color(nsColor: .windowBackgroundColor), in: self.shape)
            } else if let id, let namespace {
                content.glassEffect(.regular, in: self.shape).glassEffectID(id, in: namespace)
            } else {
                content.glassEffect(.regular, in: self.shape)
            }
        }
        .transaction {
            if self.reduceMotion {
                $0.animation = nil
            }
        }
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
                let time = context.date.timeIntervalSinceReferenceDate
                Image(systemName: "sailboat")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .offset(y: sin(time * 1.6) * 3)
                    .rotationEffect(.degrees(sin(time * 1.1) * 4))
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
        ItemCardView(item: item, index: 0, isSelected: false, store: Fixtures.previewStore())
            .cardEntrance(index: 0)
            .padding()
    }
#endif
