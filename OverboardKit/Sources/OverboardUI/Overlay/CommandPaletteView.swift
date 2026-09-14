import AppKit
import SwiftUI

/// One selectable row in a command palette — the minimal shape both the
/// drawer's `ClipAction` palette and the launcher's `LauncherAction` palette
/// project onto.
struct CommandPaletteItem: Identifiable {
    let id: String
    let label: String
    let systemImage: String
    /// The modifier glyph for this row's keyboard shortcut (↩ / ⌘↩ / ⌥↩), for
    /// hosts whose rows commit via a positional keyboard shortcut (the
    /// launcher's ↩/⌘↩/⌥↩ triad — see `LauncherActions.hint(at:)`). `nil` for
    /// hosts with no such convention (the drawer's palette).
    var hint: String?
}

/// The ⌘K command-palette chrome, factored out of `ActionPalette` so the
/// launcher can reuse it: a query field over a filtered, keyboard-navigable
/// row list, floating on an independent menu surface. Owns no domain logic — the caller
/// supplies the rows, binds query/index, and handles `onRun`.
struct CommandPaletteView: View {
    let items: [CommandPaletteItem]
    @Binding var query: String
    @Binding var index: Int
    /// The placeholder shown when no rows match (kept configurable so each host
    /// keeps its own wording).
    let emptyMessage: String
    let onRun: (Int) -> Void
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Type an action…", text: self.$query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused(self.$queryFocused)
            }
            .padding(12)

            Divider()

            if self.items.isEmpty {
                Text(self.emptyMessage)
                    .font(.callout)
                    .contrastAwareForeground(.tertiary)
                    .padding(14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(self.items.enumerated()), id: \.element.id) { index, item in
                                self.row(item, isHighlighted: index == self.index)
                                    .id(item.id)
                                    .onTapGesture {
                                        self.onRun(index)
                                    }
                            }
                        }
                        .padding(6)
                    }
                    // A bare ScrollView has no natural "hug my content" height —
                    // it greedily fills whatever it's offered — so an explicit
                    // height keyed to the row count is what lets a short list
                    // (the common case) stay content-sized instead of ballooning
                    // to fill the palette's floating position, while a longer
                    // one caps at `maxVisibleRows` and scrolls.
                    .frame(height: self.listHeight)
                    .onChange(of: self.index) {
                        guard self.items.indices.contains(self.index) else { return }
                        proxy.scrollTo(self.items[self.index].id)
                    }
                }
            }
        }
        .frame(width: 380)
        // A second glass shape merges into the host panel's glass and ends up
        // behind its list/preview. A native opaque fill keeps actions legible
        // over both columns, including when Reduce Transparency is enabled.
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: PanelRadius.palette))
        .overlay {
            RoundedRectangle(cornerRadius: PanelRadius.palette)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
        .onAppear { self.queryFocused = true }
        .onChange(of: self.query) {
            self.index = 0
        }
    }

    /// Approximate rendered height of one `row(_:isHighlighted:)` (its
    /// vertical padding plus one line of `.body` text) — close enough for
    /// sizing the scroll area; a pixel or two of slack doesn't matter since
    /// it only governs how many rows show before scrolling kicks in.
    private static let rowHeight: CGFloat = 32
    private static let maxVisibleRows = 8

    private var listHeight: CGFloat {
        let rows = min(self.items.count, Self.maxVisibleRows)
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * Self.rowHeight + CGFloat(rows - 1) * 2 + 12
    }

    private func row(_ item: CommandPaletteItem, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.systemImage)
                .frame(width: 18)
                .foregroundStyle(isHighlighted ? .primary : .secondary)
                .accessibilityHidden(true)
            Text(item.label)
            Spacer()
            if let hint = item.hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else if isHighlighted {
                // Hosts with no positional-shortcut convention (the drawer's
                // palette) keep the old highlighted-row-only ↩ affordance.
                Image(systemName: "return")
                    .font(.caption)
                    .contrastAwareForeground(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            isHighlighted ? SelectionTint.compact : .clear,
            in: RoundedRectangle(cornerRadius: ControlRadius.compact)
        )
        .contentShape(Rectangle())
    }
}

#if DEBUG
    #Preview("Items") {
        @Previewable @State var query = ""
        @Previewable @State var index = 0
        CommandPaletteView(
            items: [
                CommandPaletteItem(id: "paste", label: "Paste", systemImage: "doc.on.clipboard", hint: "↩"),
                CommandPaletteItem(id: "copy", label: "Copy", systemImage: "doc.on.doc", hint: "⌘↩"),
                CommandPaletteItem(
                    id: "pastePlain",
                    label: "Paste as Plain Text",
                    systemImage: "textformat",
                    hint: "⌥↩"
                ),
                CommandPaletteItem(id: "openLink", label: "Open Link in Browser", systemImage: "safari"),
            ],
            query: $query,
            index: $index,
            emptyMessage: "No matching actions for this selection",
            onRun: { _ in }
        )
        .padding(40)
    }

    #Preview("Empty") {
        @Previewable @State var query = "zzz"
        @Previewable @State var index = 0
        CommandPaletteView(
            items: [],
            query: $query,
            index: $index,
            emptyMessage: "No matching actions for this selection",
            onRun: { _ in }
        )
        .padding(40)
    }
#endif
