import SwiftUI

/// The reserved bottom bar every summonable surface ends with: the brand mark
/// on the left, the committing action and its keycap on the right. DESIGN.md's
/// Reserved Footer Rule keeps it outside scrolling content, and § Buttons puts
/// the primary action in primary foreground with the rest secondary.
struct PanelFooterBar: View {
    /// One footer action. `handler` is nil for a bar that only *advertises* a
    /// keyboard commit (the emoji picker) rather than offering a click target.
    struct Action {
        var label: String
        /// Keycap drawn after the label; `nil` uses the ↩ return glyph instead.
        var keycap: String?
        var accessibilityLabel: String?
        var handler: (() -> Void)?

        init(
            label: String,
            keycap: String? = nil,
            accessibilityLabel: String? = nil,
            handler: (() -> Void)? = nil
        ) {
            self.label = label
            self.keycap = keycap
            self.accessibilityLabel = accessibilityLabel
            self.handler = handler
        }
    }

    /// The ↩ action for the current selection. Absent when nothing is selected.
    var primary: Action?
    /// The secondary affordance (⌘K actions, ⌘↩ copy).
    var secondary: Action?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.caption)
                .accessibilityHidden(true)
            Text("Overboard")
                .font(.caption)
            Spacer(minLength: 12)
            if let primary {
                self.label(primary, emphasized: true)
                self.keycap(primary)
                if self.secondary != nil {
                    Divider().frame(height: 12)
                }
            }
            if let secondary {
                self.label(secondary, emphasized: false)
                self.keycap(secondary)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 20)
    }

    private func label(_ action: Action, emphasized: Bool) -> some View {
        Group {
            if let handler = action.handler {
                Button(action.label, action: handler).buttonStyle(.plain)
            } else {
                Text(action.label)
            }
        }
        .font(emphasized ? .caption.weight(.medium) : .caption)
        .foregroundStyle(emphasized ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .accessibilityLabel(action.accessibilityLabel ?? action.label)
    }

    @ViewBuilder private func keycap(_ action: Action) -> some View {
        if let keycap = action.keycap {
            Text(keycap)
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "return")
                .font(.caption2)
                .accessibilityHidden(true)
        }
    }
}

#if DEBUG
    #Preview("Launcher footer") {
        PanelFooterBar(
            primary: .init(label: "Open", handler: {}),
            secondary: .init(label: "Actions", keycap: "⌘K", accessibilityLabel: "Actions, Command K", handler: {})
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("Emoji footer") {
        PanelFooterBar(
            primary: .init(label: "Paste"),
            secondary: .init(label: "Copy", keycap: "⌘↩")
        )
        .padding()
        .frame(width: 400)
    }

    #Preview("No selection") {
        PanelFooterBar(secondary: .init(label: "Actions", keycap: "⌘K", handler: {}))
            .padding()
            .frame(width: 400)
    }
#endif
