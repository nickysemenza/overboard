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

    /// Transparent margin between the glass shell and the borderless panel's
    /// edge; `OverlayController` adds it back when sizing the panel from
    /// `collapsedShellHeight`.
    static let outerPadding: CGFloat = 12

    public init(viewModel: DrawerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 10) {
            // The outgoing view leaves the layout instantly (`.identity`
            // removal) so the VStack never briefly holds both the strip and
            // the pane — which would squeeze the incoming view and then jump
            // once the outgoing one finally cleared. The incoming view fades
            // in (`.opacity` insertion) while the VStack's height, and the
            // glass shell drawn behind it, animate between the two states
            // under the `.motion` below.
            Group {
                if self.viewModel.previewState == .hidden {
                    self.searchBar
                    if self.viewModel.mode == .history, !self.savedSearches.isEmpty {
                        self.savedSearchBar
                    }
                    self.cardStrip
                } else {
                    PreviewPane(viewModel: self.viewModel)
                }
            }
            .transition(.asymmetric(insertion: .opacity, removal: .identity))
            Divider()
            self.footerBar
        }
        .motion(.spring(response: 0.22, dampingFraction: 0.85), value: self.viewModel.isPaletteOpen)
        .motion(DrawerViewModel.previewMotion, value: self.viewModel.previewState)
        .padding(14)
        .glassPanel(cornerRadius: PanelRadius.drawer)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            // Model geometry, not per-frame animation values, so during the
            // close spring this reports the settled collapsed height once.
            if self.viewModel.previewState == .hidden {
                self.viewModel.collapsedShellHeight = height
            }
        }
        .overlay {
            if self.viewModel.isPaletteOpen {
                ActionPalette(viewModel: self.viewModel)
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .padding(Self.outerPadding)
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

    // MARK: - Footer

    private var footerBar: some View {
        PanelFooterBar(primary: self.footerPrimaryAction, secondary: self.footerSecondaryAction)
    }

    /// "Paste to <app>" — the committing action shared by the card strip and
    /// the (non-editing) preview pane. `nil` when there's nothing to paste.
    private var pasteAction: PanelFooterBar.Action? {
        switch self.viewModel.mode {
        case .history:
            guard self.viewModel.selectedItem != nil else { return nil }
        case .snippets:
            guard !self.viewModel.snippets.isEmpty else { return nil }
        }
        return .init(
            label: String(localized: "Paste to \(self.viewModel.targetAppName)", bundle: .module)
        ) {
            self.viewModel.selectCurrent()
        }
    }

    private var footerPrimaryAction: PanelFooterBar.Action? {
        if self.viewModel.previewState == .editing {
            return .init(
                label: String(localized: "Paste edited text", bundle: .module),
                keycap: "⌘↩",
                handler: self.viewModel.commitEdit
            )
        }
        return self.pasteAction
    }

    private var footerSecondaryAction: PanelFooterBar.Action? {
        switch self.viewModel.previewState {
        case .editing:
            return .init(
                label: String(localized: "Cancel", bundle: .module),
                keycap: "esc",
                handler: self.viewModel.closePreview
            )
        case .viewing:
            guard let item = self.viewModel.selectedItem, item.kind == .text || item.kind == .link else { return nil }
            return .init(
                label: String(localized: "Edit", bundle: .module),
                keycap: "⌘E",
                handler: self.viewModel.beginEdit
            )
        case .hidden:
            switch self.viewModel.mode {
            case .history:
                return .actions { self.viewModel.togglePalette() }
            case .snippets:
                return .init(
                    label: String(localized: "History", bundle: .module),
                    keycap: "⌘/",
                    handler: self.viewModel.toggleMode
                )
            }
        }
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
