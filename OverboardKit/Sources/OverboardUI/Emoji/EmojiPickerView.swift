import OverboardCore
import SwiftUI

/// The emoji picker panel body: search bar on top, scrolling sectioned grid,
/// persistent footer. Chrome matches LauncherView so the two summonable
/// surfaces read as one family.
public struct EmojiPickerView: View {
    @Bindable var viewModel: EmojiPickerViewModel
    @FocusState private var fieldFocused: Bool
    /// The mouse-hovered cell, tracked separately from `viewModel.selectedIndex`
    /// so resting the pointer over the grid can no longer steal the keyboard
    /// selection — only a click (or ↩) commits.
    @State private var hoveredIndex: Int?

    public init(viewModel: EmojiPickerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 8) {
            self.searchBar
            Divider()
            if self.viewModel.sections.isEmpty {
                self.emptyState
            } else {
                self.grid
            }
            Divider()
            PanelFooterBar(
                primary: .init(label: String(localized: "Paste", bundle: .module)),
                secondary: .init(label: String(localized: "Copy", bundle: .module), keycap: "⌘↩")
            )
        }
        .padding(14)
        .glassPanel(cornerRadius: PanelRadius.emoji)
        .padding(12)
        .onAppear {
            self.fieldFocused = true
        }
        .onChange(of: self.viewModel.showGeneration) {
            self.fieldFocused = true
        }
    }

    private var searchBar: some View {
        PanelSearchField(
            symbol: "face.smiling",
            prompt: String(localized: "Search emoji…", bundle: .module),
            text: self.$viewModel.query,
            focus: self.$fieldFocused
        )
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(self.viewModel.sections.enumerated()), id: \.element.id) { sectionIndex, section in
                        PanelSectionHeader(title: section.title)
                        LazyVGrid(columns: Self.columns, spacing: 2) {
                            ForEach(Array(section.emoji.enumerated()), id: \.element.id) { offset, emoji in
                                // Flat index from the CAPTURED section value —
                                // SwiftUI re-evaluates stale ForEach children
                                // after the section list shrinks, so indexing a
                                // view-model array by sectionIndex here crashed
                                // (out of range) when a query collapsed ten
                                // sections into one.
                                let flatIndex = section.start + offset
                                EmojiCell(
                                    emoji: emoji,
                                    isSelected: flatIndex == self.viewModel.selectedIndex,
                                    isHovered: flatIndex == self.hoveredIndex
                                )
                                .id(EmojiPickerViewModel.cellID(section: sectionIndex, character: emoji.character))
                                .onHover { hovering in
                                    if hovering {
                                        self.hoveredIndex = flatIndex
                                    } else if self.hoveredIndex == flatIndex {
                                        self.hoveredIndex = nil
                                    }
                                }
                                .onTapGesture {
                                    self.viewModel.selectedIndex = flatIndex
                                    self.viewModel.commit(copyOnly: false)
                                }
                            }
                        }
                    }
                }
                // Row insertions while typing reflow the whole grid; animating
                // them smears glyphs mid-scroll (same fix as the launcher list).
                .transaction { $0.disablesAnimations = true }
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .onChange(of: self.viewModel.selectedIndex) {
                guard let id = self.viewModel.selectedCellID else { return }
                proxy.scrollTo(id)
            }
        }
        .clipped()
    }

    private var emptyState: some View {
        PanelEmptyState(
            mark: .symbol("face.dashed"),
            title: String(localized: "No emoji found", bundle: .module),
            subtitle: String(localized: "Try a different name or keyword.", bundle: .module)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: 2),
        count: EmojiPickerViewModel.columns
    )
}

/// One grid cell: the glyph on the launcher's selection-highlight treatment.
struct EmojiCell: View {
    let emoji: Emoji
    let isSelected: Bool
    var isHovered: Bool = false
    /// The glyph is the cell's whole content, so it scales with Dynamic Type
    /// rather than staying pinned at 24pt.
    @ScaledMetric(relativeTo: .title) private var glyphSize: CGFloat = 24
    @ScaledMetric(relativeTo: .title) private var cellHeight: CGFloat = 38

    var body: some View {
        Text(self.emoji.character)
            .font(.system(size: self.glyphSize))
            .frame(maxWidth: .infinity)
            .frame(height: self.cellHeight)
            .background(self.fill, in: RoundedRectangle(cornerRadius: ControlRadius.inset))
            .contentShape(RoundedRectangle(cornerRadius: ControlRadius.inset))
            .help(self.emoji.name)
            .accessibilityLabel(self.emoji.name)
            .accessibilityAddTraits(self.isSelected ? .isSelected : [])
    }

    private var fill: Color {
        if self.isSelected {
            return SelectionTint.compact
        }
        if self.isHovered {
            return SelectionTint.hover
        }
        return .clear
    }
}

#if DEBUG
    #Preview("Category grid") {
        EmojiPickerView(viewModel: Fixtures.emojiPickerViewModel())
            .frame(width: 400, height: 460)
    }

    #Preview("Recently used") {
        EmojiPickerView(viewModel: Fixtures.emojiPickerViewModel(recents: ["🔥", "🍕", "👍"]))
            .frame(width: 400, height: 460)
    }

    #Preview("Search results") {
        let viewModel = Fixtures.emojiPickerViewModel()
        viewModel.query = "lo"
        return EmojiPickerView(viewModel: viewModel)
            .frame(width: 400, height: 460)
    }

    #Preview("Empty state") {
        let viewModel = Fixtures.emojiPickerViewModel()
        viewModel.query = "zzzzzz"
        return EmojiPickerView(viewModel: viewModel)
            .frame(width: 400, height: 460)
    }

    #Preview("Dark") {
        EmojiPickerView(viewModel: Fixtures.emojiPickerViewModel())
            .frame(width: 400, height: 460)
            .preferredColorScheme(.dark)
    }

    #Preview("Cell: unselected") {
        EmojiCell(
            emoji: Emoji(character: "🔥", name: "fire", keywords: [], category: .travel, version: 0.6),
            isSelected: false
        )
        .padding()
        .frame(width: 80)
    }

    #Preview("Cell: selected") {
        EmojiCell(
            emoji: Emoji(character: "🔥", name: "fire", keywords: [], category: .travel, version: 0.6),
            isSelected: true
        )
        .padding()
        .frame(width: 80)
    }
#endif
