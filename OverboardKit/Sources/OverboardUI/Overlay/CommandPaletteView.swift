import SwiftUI

/// One selectable row in a command palette — the minimal shape both the
/// drawer's `ClipAction` palette and the launcher's `LauncherAction` palette
/// project onto.
struct CommandPaletteItem: Identifiable {
    let id: String
    let label: String
    let systemImage: String
}

/// The ⌘K command-palette chrome, factored out of `ActionPalette` so the
/// launcher can reuse it: a query field over a filtered, keyboard-navigable
/// row list, floating in a glass card. Owns no domain logic — the caller
/// supplies the rows, binds query/index, and handles `onRun`.
struct CommandPaletteView: View {
    let items: [CommandPaletteItem]
    @Binding var query: String
    @Binding var index: Int
    /// The placeholder shown when no rows match (kept configurable so each host
    /// keeps its own wording).
    let emptyMessage: String
    let onRun: (Int) -> Void
    /// The host panel's glass namespace, shared via `GlassEffectContainer` so this
    /// palette morphs out of the panel instead of cross-fading in. Nil when
    /// hosted standalone (e.g. snapshot tests) — the palette then renders as
    /// its own independent glass shape.
    var glassNamespace: Namespace.ID?

    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(.tertiary)
                    .padding(14)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(self.items.enumerated()), id: \.element.id) { index, item in
                        self.row(item, isHighlighted: index == self.index)
                            .onTapGesture {
                                self.onRun(index)
                            }
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 380)
        .glassPanel(cornerRadius: 12, id: "palette", in: self.glassNamespace)
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
        .onAppear { self.queryFocused = true }
        .onChange(of: self.query) {
            self.index = 0
        }
    }

    private func row(_ item: CommandPaletteItem, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.systemImage)
                .frame(width: 18)
                .foregroundStyle(isHighlighted ? .primary : .secondary)
            Text(item.label)
            Spacer()
            if isHighlighted {
                Image(systemName: "return")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            isHighlighted ? Color.accentColor.opacity(0.22) : .clear,
            in: RoundedRectangle(cornerRadius: 7)
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
                CommandPaletteItem(id: "paste", label: "Paste", systemImage: "doc.on.clipboard"),
                CommandPaletteItem(id: "copy", label: "Copy", systemImage: "doc.on.doc"),
                CommandPaletteItem(id: "pastePlain", label: "Paste as Plain Text", systemImage: "textformat"),
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
