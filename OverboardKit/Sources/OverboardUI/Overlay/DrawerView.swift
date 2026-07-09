import Defaults
import OverboardCore
import OverboardMac
import SwiftUI

public struct DrawerView: View {
    @Bindable var viewModel: DrawerViewModel
    @FocusState private var searchFocused: Bool
    @Environment(\.openSettings) private var openSettings
    @Default(.savedSearches) private var savedSearches

    public init(viewModel: DrawerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 10) {
            if self.viewModel.previewState == .hidden {
                self.searchBar
                if self.viewModel.mode == .history, !self.savedSearches.isEmpty {
                    self.savedSearchBar
                }
                self.cardStrip
                self.footerHints
            } else {
                PreviewPane(viewModel: self.viewModel)
            }
        }
        .overlay {
            if self.viewModel.isPaletteOpen {
                ActionPalette(viewModel: self.viewModel)
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: self.viewModel.isPaletteOpen)
        .padding(14)
        .glassPanel(cornerRadius: 16)
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .padding(12)
        .onAppear {
            self.searchFocused = true
            // The overlay controller can't reach SwiftUI environment actions;
            // hand it the capability.
            self.viewModel.onOpenSettings = {
                self.openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .onChange(of: self.viewModel.query) {
            self.viewModel.scheduleSearch()
        }
        .onChange(of: self.viewModel.previewState) {
            if self.viewModel.previewState == .hidden {
                self.searchFocused = true
            }
        }
        .onChange(of: self.viewModel.isPaletteOpen) {
            // The ⌘K palette owns focus while open; when it closes, first
            // responder isn't returned automatically, so typed characters would
            // be dropped until the user clicks back into the field.
            if !self.viewModel.isPaletteOpen {
                self.searchFocused = true
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: self.viewModel.mode == .history ? "magnifyingglass" : "text.badge.star")
                .foregroundStyle(.secondary)
            TextField(
                self.viewModel.mode == .history ? "Search your clipboard…" : "Search snippets…",
                text: self.$viewModel.query
            )
            .textFieldStyle(.plain)
            .font(.title3)
            .focused(self.$searchFocused)

            if self.canSaveCurrentSearch {
                Button {
                    self.saveCurrentSearch()
                } label: {
                    Image(systemName: "bookmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Save this search")
            }

            if self.viewModel.stack.count > 0 {
                Text("Stack: \(self.viewModel.stack.count)")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
            }

            if self.viewModel.entryCount > 0 {
                Text("\(self.viewModel.entryCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 6)
    }

    /// Pinned-search chips: tap to run, right-click to remove.
    private var savedSearchBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(self.savedSearches, id: \.self) { query in
                    Button {
                        self.viewModel.query = query
                    } label: {
                        Text(SavedSearch.label(for: query))
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove", role: .destructive) {
                            self.removeSavedSearch(query)
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private var canSaveCurrentSearch: Bool {
        guard self.viewModel.mode == .history else { return false }
        let trimmed = self.viewModel.query.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !self.savedSearches.contains(trimmed)
    }

    private func saveCurrentSearch() {
        let trimmed = self.viewModel.query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !self.savedSearches.contains(trimmed) else { return }
        self.savedSearches.append(trimmed)
    }

    private func removeSavedSearch(_ query: String) {
        self.savedSearches.removeAll { $0 == query }
    }

    private var cardStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    switch self.viewModel.mode {
                    case .history:
                        self.historyCards
                    case .snippets:
                        self.snippetCards
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
            }
            // New generation per summon → entrance animations replay.
            .id(self.viewModel.showGeneration)
            .onChange(of: self.viewModel.selectedIndex) {
                self.scrollToSelection(proxy)
            }
            .onChange(of: self.viewModel.mode) {
                self.scrollToSelection(proxy)
            }
        }
        .frame(height: 184)
        .overlay {
            if self.viewModel.entryCount == 0 {
                self.emptyState
            }
        }
    }

    private var historyCards: some View {
        ForEach(Array(self.viewModel.items.enumerated()), id: \.element.id) { index, item in
            ItemCardView(
                item: item,
                index: index,
                isSelected: self.viewModel.isIndexSelected(index),
                store: self.viewModel.storeForCards,
                applicableActions: self.viewModel.isIndexSelected(index)
                    ? self.viewModel.applicableActions
                    : ClipAction.applicable(to: [item]),
                onRunAction: { action in
                    if !self.viewModel.isIndexSelected(index) {
                        self.viewModel.selectedIndex = index
                        self.viewModel.collapseMultiSelection()
                    }
                    self.viewModel.runAction(action)
                },
                onPinToggle: {
                    self.viewModel.selectedIndex = index
                    self.viewModel.togglePinSelected()
                },
                onDelete: {
                    self.viewModel.selectedIndex = index
                    self.viewModel.deleteSelected()
                },
                onPaste: { mode in
                    self.viewModel.select(at: index, mode: mode)
                },
                onTransform: { transform in
                    self.viewModel.selectTransformed(at: index, transform: transform)
                },
                onAITransform: { transform in
                    self.viewModel.selectAITransformed(at: index, transform: transform)
                },
                onPreview: {
                    self.viewModel.selectedIndex = index
                    self.viewModel.collapseMultiSelection()
                    self.viewModel.togglePreview()
                }
            )
            .cardEntrance(index: index)
            .zIndex(self.viewModel.isIndexSelected(index) ? 1 : 0)
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.command) {
                    self.viewModel.toggleSelection(at: index)
                } else {
                    self.viewModel.select(at: index)
                }
            }
        }
    }

    private var snippetCards: some View {
        ForEach(Array(self.viewModel.snippets.enumerated()), id: \.element.id) { index, snippet in
            SnippetCardView(
                snippet: snippet,
                index: index,
                isSelected: index == self.viewModel.selectedIndex
            )
            .cardEntrance(index: index)
            .onTapGesture {
                self.viewModel.select(at: index)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if self.viewModel.mode == .history {
                BobbingBoat()
            } else {
                Image(systemName: "text.badge.star")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
            Text(self.emptyTitle)
                .font(.headline)
            Text(self.emptyDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyTitle: String {
        switch self.viewModel.mode {
        case .history: self.viewModel.query.isEmpty ? "Nothing captured yet" : "No matches"
        case .snippets: self.viewModel.query.isEmpty ? "No snippets yet" : "No matches"
        }
    }

    private var emptyDescription: String {
        switch self.viewModel.mode {
        case .history:
            self.viewModel.query.isEmpty ? "Copy something and it'll wash up here." : "Try a different search."
        case .snippets:
            self.viewModel.query.isEmpty
                ? "Add snippets from the menu bar → Snippets…"
                : "Try a different search."
        }
    }

    private var footerHints: some View {
        Text(self.viewModel.mode == .history
            ? "↩ paste   ⇧↩ plain   space preview   ⌘K actions   ⌘E edit   ⌘↩ stack   ⌘P pin   ⌘/ snippets"
            : "↩ paste snippet   ⌘/ history   esc dismiss")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        let id: String? = switch self.viewModel.mode {
        case .history:
            self.viewModel.items.indices.contains(self.viewModel.selectedIndex)
                ? self.viewModel.items[self.viewModel.selectedIndex].id : nil
        case .snippets:
            self.viewModel.snippets.indices.contains(self.viewModel.selectedIndex)
                ? self.viewModel.snippets[self.viewModel.selectedIndex].id : nil
        }
        guard let id else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}
