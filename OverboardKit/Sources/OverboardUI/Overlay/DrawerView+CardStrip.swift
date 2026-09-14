import OverboardCore
import SwiftUI

// MARK: - Card strip

extension DrawerView {
    var cardStrip: some View {
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
        .frame(height: CardMetrics.stripHeight(cardHeight: self.cardHeight))
        .overlay {
            if self.viewModel.entryCount == 0 {
                self.emptyState
            }
        }
    }

    var historyCards: some View {
        // `entry.id` is the item id (see `StripEntry`), so selection tracking
        // and scroll-to-selection below — both keyed on item id — are
        // unaffected by carrying the ranking hint alongside each item.
        ForEach(Array(self.viewModel.stripEntries.enumerated()), id: \.element.id) { index, entry in
            let item = entry.item
            ItemCardView(
                item: item,
                index: index,
                isSelected: self.viewModel.isIndexSelected(index),
                store: self.viewModel.storeForCards,
                applicableActions: self.viewModel.isIndexSelected(index)
                    ? self.viewModel.applicableActions
                    : ClipAction.applicable(to: [item]),
                rankedAboveNewer: entry.rankedAboveNewer,
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

    var snippetCards: some View {
        ForEach(Array(self.viewModel.snippets.enumerated()), id: \.element.id) { index, snippet in
            SnippetCardView(
                snippet: snippet,
                index: index,
                isSelected: index == self.viewModel.selectedIndex
            )
            .cardEntrance(index: index)
            .zIndex(index == self.viewModel.selectedIndex ? 1 : 0)
            .onTapGesture {
                self.viewModel.select(at: index)
            }
        }
    }

    var emptyState: some View {
        PanelEmptyState(
            mark: self.viewModel.mode == .history ? .boat : .symbol("text.badge.star"),
            title: self.emptyTitle,
            subtitle: self.emptyDescription
        )
    }

    var emptyTitle: String {
        switch self.viewModel.mode {
        case .history:
            if self.viewModel.query.isEmpty {
                String(localized: "Nothing captured yet", bundle: .module)
            } else {
                String(localized: "No matches", bundle: .module)
            }
        case .snippets:
            if self.viewModel.query.isEmpty {
                String(localized: "No snippets yet", bundle: .module)
            } else {
                String(localized: "No matches", bundle: .module)
            }
        }
    }

    var emptyDescription: String {
        switch self.viewModel.mode {
        case .history:
            if self.viewModel.query.isEmpty {
                String(localized: "Copy something and it'll wash up here.", bundle: .module)
            } else {
                String(localized: "Try a different search.", bundle: .module)
            }
        case .snippets:
            if self.viewModel.query.isEmpty {
                String(localized: "Add snippets from the menu bar → Snippets…", bundle: .module)
            } else {
                String(localized: "Try a different search.", bundle: .module)
            }
        }
    }

    func scrollToSelection(_ proxy: ScrollViewProxy) {
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
