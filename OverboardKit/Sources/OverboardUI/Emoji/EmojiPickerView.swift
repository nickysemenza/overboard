import OverboardCore
import SwiftUI

/// The emoji picker panel body: search bar on top, scrolling sectioned grid,
/// persistent footer. Chrome matches LauncherView so the two summonable
/// surfaces read as one family.
public struct EmojiPickerView: View {
    @Bindable var viewModel: EmojiPickerViewModel
    @FocusState private var fieldFocused: Bool

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
            EmojiFooterBar()
        }
        .padding(14)
        .glassPanel(cornerRadius: PanelRadius.drawer)
        .padding(12)
        .onAppear {
            self.fieldFocused = true
        }
        .onChange(of: self.viewModel.showGeneration) {
            self.fieldFocused = true
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "face.smiling")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search emoji…", text: self.$viewModel.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused(self.$fieldFocused)
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(self.viewModel.sections.enumerated()), id: \.element.id) { sectionIndex, section in
                        LauncherSectionHeader(title: section.title)
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
                                    isSelected: flatIndex == self.viewModel.selectedIndex
                                )
                                .id(EmojiPickerViewModel.cellID(section: sectionIndex, character: emoji.character))
                                .onHover { hovering in
                                    if hovering {
                                        self.viewModel.selectedIndex = flatIndex
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
        Text("No emoji found")
            .font(.callout)
            .foregroundStyle(.secondary)
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

    var body: some View {
        Text(self.emoji.character)
            .font(.system(size: 24))
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(
                self.isSelected ? Color.accentColor.opacity(0.22) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .help(self.emoji.name)
            .accessibilityLabel(self.emoji.name)
            .accessibilityAddTraits(self.isSelected ? .isSelected : [])
    }
}

/// Persistent bottom bar advertising the two commit actions, styled after
/// LauncherFooterBar.
struct EmojiFooterBar: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.caption)
                .accessibilityHidden(true)
            Text("Overboard")
                .font(.caption)
            Spacer(minLength: 12)
            Text("Paste")
                .font(.caption)
            Image(systemName: "return")
                .font(.caption2)
                .accessibilityHidden(true)
            Divider()
                .frame(height: 12)
            Text("Copy")
                .font(.caption)
            Text("⌘↩")
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 20)
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
        EmojiCell(emoji: Emoji(character: "🔥", name: "fire", keywords: [], category: .travel, version: 0.6), isSelected: false)
            .padding()
            .frame(width: 80)
    }

    #Preview("Cell: selected") {
        EmojiCell(emoji: Emoji(character: "🔥", name: "fire", keywords: [], category: .travel, version: 0.6), isSelected: true)
            .padding()
            .frame(width: 80)
    }

    #Preview("Footer bar") {
        EmojiFooterBar()
            .padding()
            .frame(width: 400)
    }
#endif
