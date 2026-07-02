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
    /// Lets the panel controller resize as rows come and go.
    public var onResultCountChanged: (Int) -> Void = { _ in }

    /// Rows pinned under every result list (the Spotify now-playing footer).
    /// Evaluated on each `setResults` pass, so it covers the empty-query recents
    /// branch, the instant pass, and the debounced splice with one seam — the
    /// row lands last (after the web row) in every query state.
    public var pinnedResults: () -> [LauncherResult] = { [] }

    private let instantRouter: QueryRouter
    private let secondaryProviders: [any LauncherProvider]
    private var searchTask: Task<Void, Never>?

    /// Instant providers (apps) answer from memory and render on every
    /// keystroke alongside the calculator; secondary providers (files) run
    /// in the debounced pass and splice in above the web row.
    public init(instantProviders: [any LauncherProvider] = [], secondaryProviders: [any LauncherProvider]) {
        self.instantRouter = QueryRouter(
            providers: [CommandProvider(), CalculatorProvider()] + instantProviders + [WebSearchProvider()]
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

    public func commit(modifier: CommitModifier = .none) {
        guard self.results.indices.contains(self.selectedIndex) else { return }
        switch self.results[self.selectedIndex] {
        case let .calculation(_, display):
            modifier == .command ? self.onPasteText(display) : self.onCopyText(display)
        case let .app(_, url), let .file(_, url):
            switch modifier {
            case .none: self.onOpenFile(url)
            case .command: self.onRevealFile(url)
            case .option: self.onCopyPath(url.path)
            }
        case let .snippet(snippet):
            modifier == .command ? self.onCopySnippet(snippet) : self.onPasteSnippet(snippet)
        case let .clip(item):
            switch modifier {
            case .none: self.onPasteClip(item, .full)
            case .command: self.onCopyClip(item)
            case .option: self.onPasteClip(item, .plainText)
            }
        case let .webSearch(_, url):
            self.onOpenWebSearch(url)
        case let .systemSetting(_, url):
            self.onOpenSystemSetting(url)
        case let .command(command):
            self.onRunCommand(command)
        case let .nowPlaying(track):
            modifier == .command ? self.onOpenSpotify(track) : self.onCopyNowPlayingLink(track)
        case let .recentSearch(query):
            // Re-run the past search in place — refill the bar, stay open.
            self.query = query
            self.selectedIndex = 0
            self.scheduleSearch()
        }
    }

    private func setResults(_ newResults: [LauncherResult]) {
        // Pinned rows (Spotify now-playing) trail every list. Routing all
        // mutations through here means the footer appears on the empty-query
        // recents, the instant pass, and the debounced splice alike.
        let combined = newResults + self.pinnedResults()
        obTrace("launcher results: \(combined.map(\.id))")
        let countChanged = combined.count != self.results.count
        self.results = combined
        if self.selectedIndex >= combined.count {
            self.selectedIndex = max(combined.count - 1, 0)
        }
        if countChanged {
            self.onResultCountChanged(combined.count)
        }
    }
}
