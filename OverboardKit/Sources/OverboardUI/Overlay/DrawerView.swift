import Defaults
import OverboardCore
import OverboardMac
import SwiftUI

public struct DrawerView: View {
    @Bindable var viewModel: DrawerViewModel
    @FocusState private var searchFocused: Bool
    @Environment(\.openSettings) private var openSettings
    @Default(.savedSearches) private var savedSearches
    /// Card height for the strip; the drawer panel itself is sized from the
    /// unscaled base in `CardMetrics` (see its note on macOS Dynamic Type).
    @ScaledMetric(relativeTo: .callout) var cardHeight: CGFloat = CardMetrics.height

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
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: self.viewModel.isPaletteOpen)
        .padding(14)
        .glassPanel(cornerRadius: PanelRadius.drawer)
        .overlay {
            if self.viewModel.isPaletteOpen {
                ActionPalette(viewModel: self.viewModel)
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
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
        PanelSearchField(
            symbol: self.viewModel.mode == .history ? "magnifyingglass" : "text.badge.star",
            prompt: self.viewModel.mode == .history
                ? String(localized: "Search your clipboard…", bundle: .module)
                : String(localized: "Search snippets…", bundle: .module),
            text: self.$viewModel.query,
            focus: self.$searchFocused
        ) {
            Button("Browse History", systemImage: "list.bullet.rectangle", action: self.viewModel.onBrowseHistory)
                .buttonStyle(.plain).font(.caption).help("Open searchable history with a preview")

            if self.canSaveCurrentSearch {
                Button {
                    self.saveCurrentSearch()
                } label: {
                    Image(systemName: "bookmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Save this search")
                .accessibilityLabel("Save search")
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
                    .contrastAwareForeground(.tertiary)
                    .accessibilityLabel("\(self.viewModel.entryCount) entries")
            }
        }
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

    private var footerHints: some View {
        Text(self.viewModel.mode == .history
            ? "↩ paste   ⇧↩ plain   space preview   ⌘K actions   ⌘E edit   ⌘↩ stack   ⌘P pin   ⌘/ snippets"
            : "↩ paste snippet   ⌘/ history   esc dismiss")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

#if DEBUG
    #Preview("History") {
        SeededPreview { store in
            DrawerView(viewModel: Fixtures.drawerViewModel(store: store))
        }
        // Matches OverlayController's collapsed panel frame (full screen width);
        // a fixed 900pt stands in for the screen width in previews.
        .frame(width: 900, height: CardMetrics.collapsedPanelHeight)
    }

    #Preview("Empty") {
        SeededPreview { store in
            let viewModel = Fixtures.drawerViewModel(store: store)
            viewModel.query = "zzzzzz no matches zzzzzz"
            viewModel.scheduleSearch()
            return DrawerView(viewModel: viewModel)
        }
        .frame(width: 900, height: CardMetrics.collapsedPanelHeight)
    }
#endif
