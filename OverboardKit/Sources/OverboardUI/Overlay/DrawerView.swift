import OverboardCore
import SwiftUI

public struct DrawerView: View {
    @Bindable var viewModel: DrawerViewModel
    @FocusState private var searchFocused: Bool
    @Environment(\.openSettings) private var openSettings

    public init(viewModel: DrawerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 10) {
            if self.viewModel.previewState == .hidden {
                self.searchBar
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
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
                }
            )
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
            .onTapGesture {
                self.viewModel.select(at: index)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(self.emptyTitle, systemImage: self.viewModel.mode == .history ? "sailboat" : "text.badge.star")
        } description: {
            Text(self.emptyDescription)
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
