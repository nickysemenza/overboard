import AppKit
import OverboardCore
import OverboardMac
import SwiftUI
import UniformTypeIdentifiers

/// THESIS: Make the selected result recognizable and its action predictable.
/// OWN-WORLD: macOS system type, native icons, restrained glass, one accent selection.
/// STORY: Type, recognize the result, inspect when useful, press Return.
/// FIRST VIEWPORT: Search and scopes above a bounded list; adjacent preview on
/// demand; primary action in a reserved footer that never overlaps results.
/// FORM: User-approved compact launcher plus list/detail clipboard browser;
/// an extension of the existing native design, not a new visual-world selection.
/// FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, and
/// DESIGN.md
public struct LauncherView: View {
    @Bindable var viewModel: LauncherViewModel
    let store: ClipStore
    @FocusState private var fieldFocused: Bool
    /// Gates the search-bar spinner behind a short delay so it doesn't
    /// flicker on every keystroke — `isSearching` is true through the whole
    /// 120 ms debounce window (stream 2a), not just while a request is
    /// actually in flight.
    @State private var showSpinner = false
    @State private var spinnerDelayTask: Task<Void, Never>?

    public init(viewModel: LauncherViewModel, store: ClipStore) {
        self.viewModel = viewModel
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            self.searchBar
            self.scopeBar
            if self.viewModel.scope == .clipboard {
                self.clipboardFilters
            }
            Divider()
            HStack(spacing: 0) {
                self.resultList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if self.viewModel.showsPreview {
                    Divider()
                    LauncherPreview(
                        result: self.viewModel.selectedResult,
                        store: self.store,
                        query: self.viewModel.query,
                        onOpen: { self.viewModel.commit() }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Overlaying just the list/preview region — rather than the
            // whole panel with a hand-tuned bottom padding to clear the
            // footer's height — anchors the palette to this region's own
            // bottom edge, which already sits directly above the (optional)
            // error banner, the divider, and the footer.
            .overlay(alignment: .bottom) {
                if self.viewModel.isPaletteOpen {
                    LauncherActionPalette(viewModel: self.viewModel)
                        .padding(.bottom, 8)
                }
            }
            if let message = self.viewModel.statusMessage {
                self.errorBanner(message)
            }
            Divider()
            PanelFooterBar(
                primary: self.viewModel.primaryAction.map { action in
                    .init(label: self.viewModel.primaryActionLabel ?? action.label) { self.viewModel.commit() }
                },
                secondary: .init(
                    label: String(localized: "Actions", bundle: .module),
                    keycap: "⌘K",
                    accessibilityLabel: String(localized: "Actions, Command K", bundle: .module)
                ) { self.viewModel.togglePalette() }
            )
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
        .glassPanel(cornerRadius: PanelRadius.launcher)
        .padding(12)
        .onAppear { self.fieldFocused = true }
        .onChange(of: self.viewModel.showGeneration) { self.fieldFocused = true }
        .onChange(of: self.viewModel.scope) { self.fieldFocused = true }
        .onChange(of: self.viewModel.isPaletteOpen) {
            if !self.viewModel.isPaletteOpen {
                self.fieldFocused = true
            }
        }
        .onChange(of: self.viewModel.query) { self.viewModel.scheduleSearch() }
        .onChange(of: self.viewModel.clipboardFilter) { self.viewModel.scheduleSearch() }
        .onChange(of: self.viewModel.isSearching) { self.scheduleSpinnerDelay() }
    }

    /// Only shows the spinner once `isSearching` has held continuously for
    /// ~300 ms; cancelled (and the spinner hidden) the moment a search
    /// finishes before that window elapses.
    private func scheduleSpinnerDelay() {
        self.spinnerDelayTask?.cancel()
        guard self.viewModel.isSearching else {
            self.showSpinner = false
            return
        }
        self.spinnerDelayTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self.showSpinner = true
        }
    }

    private var searchBar: some View {
        PanelSearchField(
            symbol: "magnifyingglass",
            prompt: self.viewModel.scope == .clipboard
                ? String(localized: "Find something you copied…", bundle: .module)
                : String(localized: "Search apps, files, clipboard, or the web…", bundle: .module),
            text: self.$viewModel.query,
            size: .large,
            accessibilityLabel: String(localized: "Search \(self.viewModel.scope.rawValue)", bundle: .module),
            focus: self.$fieldFocused
        ) {
            if self.showSpinner {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var scopeBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(LauncherScope.allCases.enumerated()), id: \.element) { index, scope in
                Button { self.viewModel.setScope(scope) } label: {
                    HStack(spacing: 6) {
                        Text(scope.rawValue).font(.subheadline.weight(.medium))
                        Text("⌘\(index + 1)").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(
                        self.viewModel.scope == scope ? Color.primary.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(self.viewModel.scope == scope ? .isSelected : [])
            }
            Spacer(minLength: 0)
            if self.viewModel.scope == .files {
                Text(FileIndexService.shared.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    private var clipboardFilters: some View {
        HStack(spacing: 8) {
            Picker("Type", selection: self.$viewModel.clipboardFilter.kind) {
                Text("All types").tag(ItemKind?.none)
                ForEach(ItemKind.allCases, id: \.self) { kind in Text(kind.displayName).tag(Optional(kind)) }
            }
            Picker("Source", selection: self.$viewModel.clipboardFilter.source) {
                Text("All apps").tag(String?.none)
                ForEach(self.viewModel.sources, id: \.self) { Text($0).tag(Optional($0)) }
            }
            Picker("Copied", selection: self.$viewModel.clipboardFilter.period) {
                ForEach(ClipboardFilter.Period.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Toggle(isOn: self.$viewModel.clipboardFilter.pinnedOnly) {
                Image(systemName: "pin").accessibilityLabel("Pinned only")
            }.toggleStyle(.button).help("Pinned only")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .labelsHidden().controlSize(.small).padding(.horizontal, 16).padding(.bottom, 10)
    }

    /// A store/search failure (e.g. clipboard FTS erroring out) gets a tinted,
    /// actionable banner instead of a faint secondary caption — DESIGN.md's
    /// "don't use faint text to solve density or hierarchy problems for
    /// actionable hints" applies here since Retry is a real recovery action.
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
            Spacer(minLength: 8)
            Button("Retry") { self.viewModel.scheduleSearch(preserveSelection: true) }
                .buttonStyle(.plain)
                .font(.callout.weight(.medium))
            Button {
                self.viewModel.statusMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: PanelRadius.palette))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(self.viewModel.results.enumerated()), id: \.element.id) { index, result in
                        if let header = self.historyHeader(at: index) {
                            PanelSectionHeader(title: header)
                        }
                        // Computed once per search pass in the view model
                        // (batched into one store call) rather than per row.
                        let excerpt: String? = if case let .clip(item) = result {
                            self.viewModel.matchExcerpts[item.id]
                        } else {
                            nil
                        }
                        LauncherRow(
                            result: result,
                            store: self.store,
                            isSelected: index == self.viewModel.selectedIndex,
                            runningAppPaths: self.viewModel.runningAppPaths,
                            query: self.viewModel.query,
                            showsSourceBadge: self.viewModel.scope != .clipboard,
                            excerpt: excerpt,
                            actions: self.viewModel.actions(for: result),
                            onSelect: { self.viewModel.select(at: index) },
                            onCommit: { self.viewModel.select(at: index); self.viewModel.commit() },
                            onPerformAction: { action in
                                self.viewModel.select(at: index)
                                self.viewModel.perform(action)
                            }
                        )
                        .id(result.id)
                    }
                    if self.viewModel.hasMoreClipboard {
                        Button("Show more history", action: self.viewModel.loadMoreClipboard)
                            .buttonStyle(.plain).font(.caption).padding(12)
                    }
                }
                .padding(8)
            }
            // Centered over the whole scroll viewport instead of living inside
            // the LazyVStack, where it used to hug the top with dead space
            // below. Hidden entirely while a search is still in flight — the
            // previous list stays on screen by design (stream 2a) — so it
            // only ever describes the *current* list, never a stale one.
            .overlay {
                if !self.viewModel.isSearching, self.viewModel.results.isEmpty {
                    self.emptyState
                }
            }
            .onChange(of: self.viewModel.selectedResult?.id) {
                if let id = self.viewModel.selectedResult?.id {
                    proxy.scrollTo(id)
                }
            }
            .onChange(of: self.viewModel.results.count) {
                if let id = self.viewModel.selectedResult?.id {
                    proxy.scrollTo(id)
                }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        let query = self.viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            PanelEmptyState(
                mark: .symbol("magnifyingglass"),
                title: String(localized: "No results for “\(query)”", bundle: .module),
                subtitle: String(localized: "Check the spelling or try a new search.", bundle: .module)
            )
        } else if self.viewModel.scope == .clipboard {
            PanelEmptyState(
                mark: .symbol("doc.on.clipboard"),
                title: String(localized: "No results", bundle: .module),
                subtitle: String(localized: "Copy something, or try a different search or filter.", bundle: .module)
            )
        } else {
            PanelEmptyState(
                mark: .symbol("magnifyingglass"),
                title: String(localized: "No results", bundle: .module),
                subtitle: String(localized: "Try a shorter name or choose another scope.", bundle: .module)
            )
        }
    }

    private func historyHeader(at index: Int) -> String? {
        if self.viewModel.scope == .all, self.viewModel.query.isEmpty {
            switch self.viewModel.results[index] {
            case .app: return index == 0 ? "Suggestions" : nil
            case .recentSearch:
                if index > 0, case .recentSearch = self.viewModel.results[index - 1] {
                    return nil
                }
                return "Recent searches"
            default: return nil
            }
        }
        guard self.viewModel.scope == .clipboard, self.viewModel.query.isEmpty,
              case let .clip(item) = self.viewModel.results[index] else { return nil }
        func label(_ date: Date) -> String {
            if Calendar.current.isDateInToday(date) {
                return "Today"
            }
            if Calendar.current.isDateInYesterday(date) {
                return "Yesterday"
            }
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        let title = label(item.lastUsedAt)
        if index > 0, case let .clip(previous) = self.viewModel.results[index - 1],
           label(previous.lastUsedAt) == title
        {
            return nil
        }
        return title
    }
}

#if DEBUG
    #Preview("Sections") {
        let viewModel = LauncherViewModel(
            instantProviders: [StubLauncherProvider(rows: [
                .app(name: "Demo App", url: URL(fileURLWithPath: "/Applications/OverboardDemo.app")),
                .clip(Fixtures.item(preview: "deploy checklist")),
                .file(name: "notes.md", url: URL(fileURLWithPath: "/tmp/overboard-missing/notes.md")),
            ])],
            secondaryProviders: []
        )
        viewModel.query = "zzz"
        viewModel.scheduleSearch()
        return LauncherView(viewModel: viewModel, store: Fixtures.previewStore())
            .frame(width: 640, height: 370)
    }

#endif
