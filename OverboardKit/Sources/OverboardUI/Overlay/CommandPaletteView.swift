import AppKit
import SwiftUI

/// One selectable row in a command palette — the minimal shape both the
/// drawer's `ClipAction` palette and the launcher's `LauncherAction` palette
/// project onto.
struct CommandPaletteItem: Identifiable {
    let id: String
    let label: String
    let systemImage: String
    var hint: String?
    var detail: String?
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
    var maximumHeight: CGFloat = 320
    @State private var measuredContentHeight: CGFloat = 240
    /// The query row's height is pinned rather than left to the text field:
    /// a plain `TextField` reports a slightly different height before and
    /// after it takes focus, which moved the whole palette by a few points
    /// between two otherwise identical renders.
    @ScaledMetric(relativeTo: .title3) private var queryHeight: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                NativePaletteQueryField(text: self.$query)
            }
            .frame(height: self.queryHeight)
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
                                Button { self.onRun(index) } label: {
                                    self.row(item, isHighlighted: index == self.index)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(item.label)
                                .accessibilityHint(item.detail ?? "")
                                .accessibilityAddTraits(index == self.index ? .isSelected : [])
                                .id(item.id)
                            }
                        }
                        .padding(6)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            self.measuredContentHeight = $0
                        }
                    }
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
        .onChange(of: self.query) {
            self.index = 0
        }
    }

    private var listHeight: CGFloat {
        min(self.measuredContentHeight, max(0, self.maximumHeight - self.queryHeight - 25))
    }

    private func row(_ item: CommandPaletteItem, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.systemImage)
                .frame(width: 18)
                .foregroundStyle(isHighlighted ? .primary : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.label)
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(detail)
                }
            }
            Spacer()
            if let hint = item.hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else if isHighlighted {
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
                    hint: "⇧↩"
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
