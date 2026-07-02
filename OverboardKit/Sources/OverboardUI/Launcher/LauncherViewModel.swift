import Foundation
import Observation
import OverboardCore
import OverboardMac

/// State machine for the launcher bar: instant calculator/web rows on every
/// keystroke, Spotlight file rows spliced in after a debounce.
@MainActor
@Observable
public final class LauncherViewModel {
    public enum CommitModifier: Sendable {
        case none, command, option
    }

    public var query = ""
    public private(set) var results: [LauncherResult] = []
    public var selectedIndex = 0
    /// Bumped on every summon so the view re-asserts text-field focus
    /// (onAppear only fires once — the hosting view is reused).
    public private(set) var showGeneration = 0

    /// Recent searches, most-recent last; persisted across launches. Surfaced as
    /// the result rows when the field is empty.
    public private(set) var history: [String] = Defaults[.launcherSearchHistory]
    private let maxHistory = 20
    /// How many recents to actually show on an empty field — a short hint, not a
    /// full history dump that fills the panel.
    private let maxRecentRows = 3

    // Effects, executed by the app layer.
    public var onCopyText: (String) -> Void = { _ in }
    public var onPasteText: (String) -> Void = { _ in }
    public var onOpenFile: (URL) -> Void = { _ in }
    public var onRevealFile: (URL) -> Void = { _ in }
    public var onCopyPath: (String) -> Void = { _ in }
    public var onOpenWebSearch: (URL) -> Void = { _ in }
    public var onOpenSystemSetting: (URL) -> Void = { _ in }
    public var onPasteClip: (ClipItem, PasteMode) -> Void = { _, _ in }
    public var onCopyClip: (ClipItem) -> Void = { _ in }
    public var onPasteSnippet: (Snippet) -> Void = { _ in }
    public var onCopySnippet: (Snippet) -> Void = { _ in }
    public var onRunCommand: (LauncherCommand) -> Void = { _ in }
    public var onCopyNowPlayingLink: (NowPlayingTrack) -> Void = { _ in }
    public var onOpenSpotify: (NowPlayingTrack) -> Void = { _ in }
    /// Terminate a running app (⌘K → Quit on a running app row); the URL is the
    /// app bundle's file URL.
    public var onQuitApp: (URL) -> Void = { _ in }
    /// Open a link clip's URL in the browser (⌘K → Open Link on a link clip).
    public var onOpenClipLink: (URL) -> Void = { _ in }
    /// Lets the panel controller resize as rows and section headers come and go.
    public var onLayoutChanged: (_ rows: Int, _ headers: Int) -> Void = { _, _ in }

    /// Bundle paths of apps macOS currently reports as running. A later slice
    /// populates this (from `NSWorkspace.runningApplications`); for now it stays
    /// empty, so `isSelectedAppRunning` is always false and the "Switch to" /
    /// Quit actions never surface.
    public var runningAppPaths: Set<String> = []

    /// Rows pinned under every result list (the Spotify now-playing footer).
    /// Evaluated on each `setResults` pass, so it covers the empty-query recents
    /// branch, the instant pass, and the debounced splice with one seam — the
    /// row lands last (after the web row) in every query state.
    public var pinnedResults: () -> [LauncherResult] = { [] }

    private let instantRouter: QueryRouter
    private let secondaryProviders: [any LauncherProvider]
    private var searchTask: Task<Void, Never>?
    /// Header count of the current `results` — the panel controller sizes with
    /// it, and `setResults` only fires `onLayoutChanged` when it (or the row
    /// count) actually moves.
    public private(set) var headerCount = 0

    /// Instant providers (apps) answer from memory and render on every
    /// keystroke alongside the calculator; secondary providers (files) run
    /// in the debounced pass and splice in above the web row.
    public init(
        instantProviders: [any LauncherProvider] = [],
        secondaryProviders: [any LauncherProvider],
        commandProvider: CommandProvider = CommandProvider()
    ) {
        self.instantRouter = QueryRouter(
            providers: [commandProvider, CalculatorProvider()] + instantProviders + [WebSearchProvider()]
        )
        self.secondaryProviders = secondaryProviders
    }

    /// Preps state for a summon. When `clearQuery` is false the previous `query`
    /// is kept so a quickly-reopened launcher resumes where it left off;
    /// `scheduleSearch()` repopulates its rows (and clears them when the query is
    /// empty). When `clearQuery` is true the bar opens fresh.
    public func prepareForShow(clearQuery: Bool) {
        self.searchTask?.cancel()
        if clearQuery {
            self.query = ""
        }
        // Pick up entries this session has saved since the model was created so
        // the empty-field recents list is current.
        self.history = Defaults[.launcherSearchHistory]
        self.selectedIndex = 0
        self.showGeneration += 1
        self.scheduleSearch()
    }

    public func scheduleSearch() {
        self.searchTask?.cancel()
        let query = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            // Empty field shows recent searches as the result list (most-recent
            // first); committing a row refills the bar and re-runs it.
            self.selectedIndex = 0
            self.setResults(
                self.history.reversed().prefix(self.maxRecentRows).map { .recentSearch(query: $0) }
            )
            return
        }
        self.searchTask = Task {
            // Calculator + web are effectively synchronous — show them now.
            let instant = await self.instantRouter.results(for: query)
            guard !Task.isCancelled else { return }
            self.selectedIndex = 0
            self.setResults(instant)

            // Command mode (":…") is instant-only — no clip/file/Spotlight rows.
            guard !query.hasPrefix(":") else { return }

            let providers = self.secondaryProviders
            guard !providers.isEmpty else { return }
            // Debounce Spotlight; per-keystroke metadata queries are wasteful.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }

            // Splice each provider's rows in as it finishes — apps come back
            // well before the broad home-folder file query, and waiting for
            // the slowest provider made the whole bar feel sluggish.
            let head = instant.filter { if case .webSearch = $0 { false } else { true } }
            let tail = instant.filter { if case .webSearch = $0 { true } else { false } }
            var buckets = [[LauncherResult]](repeating: [], count: providers.count)
            await withTaskGroup(of: (Int, [LauncherResult]).self) { group in
                for (index, provider) in providers.enumerated() {
                    group.addTask { await (index, provider.results(for: query)) }
                }
                for await (index, rows) in group {
                    guard !Task.isCancelled else { return }
                    buckets[index] = rows
                    self.setResults(head + buckets.flatMap(\.self) + tail)
                }
            }
        }
    }

    public func moveSelection(_ delta: Int) {
        guard !self.results.isEmpty else { return }
        self.selectedIndex = min(max(self.selectedIndex + delta, 0), self.results.count - 1)
    }

    // MARK: - Search history

    /// Save the current query as the most-recent history entry. Called on every
    /// dismissal (commit / escape / click-outside); no-ops on empty queries.
    public func recordCurrentQuery() {
        let trimmed = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = self.history
        updated.removeAll { $0 == trimmed }
        updated.append(trimmed)
        if updated.count > self.maxHistory {
            updated.removeFirst(updated.count - self.maxHistory)
        }
        self.history = updated
        Defaults[.launcherSearchHistory] = updated
    }

    /// Removes the selected recent-search row from history (⌘⌫ on the empty
    /// field). Returns true only when a recent was actually deleted, so the
    /// caller can swallow the keystroke; any other row kind is left untouched.
    @discardableResult
    public func deleteSelectedRecent() -> Bool {
        guard self.results.indices.contains(self.selectedIndex),
              case let .recentSearch(query) = self.results[self.selectedIndex]
        else { return false }
        var updated = self.history
        updated.removeAll { $0 == query }
        self.history = updated
        Defaults[.launcherSearchHistory] = updated
        // Re-render the (still empty-field) recents list; setResults reclamps the
        // selection so it lands on the next row down.
        self.setResults(
            updated.reversed().prefix(self.maxRecentRows).map { .recentSearch(query: $0) }
        )
        return true
    }

    // MARK: - Commit / actions

    /// Actions available for the currently-selected row, in footer/palette
    /// order (index 0/1/2 = ↩/⌘↩/⌥↩). Empty when nothing is selected.
    public var selectedActions: [LauncherAction] {
        guard self.results.indices.contains(self.selectedIndex) else { return [] }
        return LauncherActions.actions(for: self.results[self.selectedIndex], context: self.actionContext)
    }

    /// The row's primary (↩) action — what the footer bar advertises.
    public var primaryAction: LauncherAction? {
        self.selectedActions.first
    }

    /// Whether the selected app row is one macOS reports as running. Drives
    /// the "Switch to" label and the Quit action; always false until a later
    /// slice fills `runningAppPaths`.
    public var isSelectedAppRunning: Bool {
        guard self.results.indices.contains(self.selectedIndex),
              case let .app(_, url) = self.results[self.selectedIndex]
        else { return false }
        return self.runningAppPaths.contains(url.path)
    }

    private var actionContext: LauncherActionContext {
        LauncherActionContext(isAppRunning: self.isSelectedAppRunning)
    }

    /// Keyboard commit (↩/⌘↩/⌥↩). A thin wrapper that maps the modifier to the
    /// positional action for the selected row and routes it through `perform`,
    /// so the footer, palette, and keyboard all share one execution path.
    public func commit(modifier: CommitModifier = .none) {
        let actions = self.selectedActions
        guard !actions.isEmpty else { return }
        let index: Int = switch modifier {
        case .none: 0
        case .command: 1
        // ⌥↩ maps to the third action; rows without one (snippet, calc) fall
        // back to ↩ — matching the old commit's snippet/calc option behavior.
        case .option: actions.indices.contains(2) ? 2 : 0
        }
        self.perform(actions[index])
    }

    /// Executes one action against the selected row. The single routing point
    /// for the footer's primary action, the ⌘K palette, and `commit`.
    public func perform(_ action: LauncherAction) {
        guard self.results.indices.contains(self.selectedIndex) else { return }
        let result = self.results[self.selectedIndex]
        switch (action, result) {
        case let (.copy, .calculation(_, display)):
            self.onCopyText(display)
        case let (.paste, .calculation(_, display)):
            self.onPasteText(display)
        case let (.open, .app(_, url)), let (.switchTo, .app(_, url)),
             let (.open, .file(_, url)):
            self.onOpenFile(url)
        case let (.revealInFinder, .app(_, url)), let (.revealInFinder, .file(_, url)):
            self.onRevealFile(url)
        case let (.copyPath, .app(_, url)), let (.copyPath, .file(_, url)):
            self.onCopyPath(url.path)
        case let (.quitApp, .app(_, url)):
            self.onQuitApp(url)
        case let (.paste, .snippet(snippet)):
            self.onPasteSnippet(snippet)
        case let (.copy, .snippet(snippet)):
            self.onCopySnippet(snippet)
        case let (.paste, .clip(item)):
            self.onPasteClip(item, .full)
        case let (.pastePlain, .clip(item)):
            self.onPasteClip(item, .plainText)
        case let (.copy, .clip(item)):
            self.onCopyClip(item)
        case let (.openLink, .clip(item)):
            if let url = Self.clipLinkURL(item) { self.onOpenClipLink(url) }
        case let (.search, .webSearch(_, url)):
            self.onOpenWebSearch(url)
        case let (.openSetting, .systemSetting(_, url)):
            self.onOpenSystemSetting(url)
        case let (.runCommand, .command(command, _)):
            self.onRunCommand(command)
        case let (.copyLink, .nowPlaying(track)):
            self.onCopyNowPlayingLink(track)
        case let (.openInSpotify, .nowPlaying(track)):
            self.onOpenSpotify(track)
        case let (.rerunSearch, .recentSearch(query)):
            // Re-run the past search in place — refill the bar, stay open.
            self.query = query
            self.selectedIndex = 0
            self.scheduleSearch()
        case (.removeRecent, .recentSearch):
            self.deleteSelectedRecent()
        default:
            break
        }
    }

    /// The link clip's destination URL, trimmed the same way `ClipAction.openLink`
    /// parses it. `previewText` is the launcher's available text (full payload
    /// isn't prefetched here); links are short, so it's the whole URL.
    private static func clipLinkURL(_ item: ClipItem) -> URL? {
        guard let text = item.previewText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return URL(string: text)
    }

    // MARK: - ⌘K action palette

    public private(set) var isPaletteOpen = false
    public var paletteQuery: String = ""
    public var paletteIndex: Int = 0

    /// Actions for the selected row filtered by a case-insensitive substring of
    /// the label; empty query shows them all.
    public var filteredPaletteActions: [LauncherAction] {
        let all = self.selectedActions
        let needle = self.paletteQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { $0.label.lowercased().contains(needle) }
    }

    /// Opens the palette (only when a row with actions is selected) or closes it
    /// if already open.
    public func togglePalette() {
        if self.isPaletteOpen {
            self.closePalette()
        } else {
            guard !self.selectedActions.isEmpty else { return }
            self.paletteQuery = ""
            self.paletteIndex = 0
            self.isPaletteOpen = true
        }
    }

    public func closePalette() {
        self.isPaletteOpen = false
    }

    public func movePaletteSelection(_ delta: Int) {
        let count = self.filteredPaletteActions.count
        guard count > 0 else { return }
        self.paletteIndex = min(max(self.paletteIndex + delta, 0), count - 1)
    }

    public func runPaletteAction(at index: Int? = nil) {
        let actions = self.filteredPaletteActions
        let chosen = index ?? self.paletteIndex
        guard actions.indices.contains(chosen) else { return }
        self.closePalette()
        self.perform(actions[chosen])
    }

    private func setResults(_ newResults: [LauncherResult]) {
        // Pinned rows (Spotify now-playing) trail every list. Routing all
        // mutations through here means the footer appears on the empty-query
        // recents, the instant pass, and the debounced splice alike.
        let combined = newResults + self.pinnedResults()
        obTrace("launcher results: \(combined.map(\.id))")
        // Same annotation the view renders — header rows add panel height too.
        let headers = LauncherSection.annotate(combined).count { $0.header != nil }
        let layoutChanged = combined.count != self.results.count || headers != self.headerCount
        self.results = combined
        self.headerCount = headers
        if self.selectedIndex >= combined.count {
            self.selectedIndex = max(combined.count - 1, 0)
        }
        if layoutChanged {
            self.onLayoutChanged(combined.count, headers)
        }
    }
}
