import AsyncAlgorithms
import Foundation
import Observation
import os
import OverboardCore
import OverboardMac

/// State machine for the launcher bar: instant calculator/web rows on every
/// keystroke, indexed file rows merged by relevance as they arrive.
@Observable
public final class LauncherViewModel {
    public enum CommitModifier: Sendable {
        case none, command, option
    }

    /// How an "Ask AI" row delivers its result: ↩ pastes into the target app,
    /// ⌘↩ copies to the clipboard.
    public enum AskAIDelivery: Sendable {
        case paste, copy
    }

    public var query = ""
    public private(set) var results: [LauncherResult] = []
    public var selectedIndex = 0
    public var scope: LauncherScope = .all
    public var clipboardFilter = ClipboardFilter()
    public private(set) var sources: [String] = []
    public private(set) var hasMoreClipboard = false
    private var clipboardLimit = 200
    public var targetAppName = "previous app"
    public var isPreviewVisible = false
    public var statusMessage: String?
    public private(set) var isSearching = false
    private var userSelected = false
    private let clipboardStore: ClipStore?
    private var observationTask: Task<Void, Never>?

    public var selectedResult: LauncherResult? {
        self.results.indices.contains(self.selectedIndex) ? self.results[self.selectedIndex] : nil
    }

    public var showsPreview: Bool {
        self.scope == .clipboard || self.isPreviewVisible
    }

    public var primaryActionLabel: String? {
        guard let action = self.primaryAction else { return nil }
        if action == .paste { return "Paste to \(self.targetAppName)" }
        if action == .search { return "Search Google" }
        return action.label
    }

    public func setScope(_ scope: LauncherScope) {
        guard self.scope != scope else { return }
        self.scope = scope
        self.isPreviewVisible = false
        self.closePalette()
        self.scheduleSearch()
        self.onLayoutChanged()
    }

    public func togglePreview() {
        guard self.selectedResult != nil else { return }
        self.userSelected = true
        self.isPreviewVisible.toggle()
        self.onLayoutChanged()
    }

    public func loadMoreClipboard() {
        self.clipboardLimit += 200
        self.scheduleSearch(preserveSelection: true)
    }

    public func select(at index: Int) {
        guard self.results.indices.contains(index) else { return }
        self.userSelected = true
        self.selectedIndex = index
    }

    public func startObserving() {
        guard let clipboardStore else { return }
        self.observationTask?.cancel()
        self.observationTask = Task { [weak self] in
            do {
                for try await _ in clipboardStore.observeRecent() {
                    guard !Task.isCancelled, let self else { return }
                    self.scheduleSearch(preserveSelection: true)
                }
            } catch {
                self?.statusMessage = "Clipboard updates paused. Reopen to try again."
            }
        }
    }

    public func stopObserving() {
        self.observationTask?.cancel()
        self.observationTask = nil
        self.searchTask?.cancel()
    }

    /// Bumped on every summon so the view re-asserts text-field focus
    /// (onAppear only fires once — the hosting view is reused).
    public private(set) var showGeneration = 0

    /// Recent searches, most-recent last; persisted across launches. Surfaced as
    /// the result rows when the field is empty.
    public private(set) var history: [String] = Defaults[.launcherSearchHistory]
    private static let maxHistory = 20
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
    /// Run a free-text Apple Intelligence prompt over the clipboard text and
    /// deliver the result (↩ paste / ⌘↩ copy).
    public var onAskAI: (String, AskAIDelivery) -> Void = { _, _ in }
    /// Terminate a running app (⌘K → Quit on a running app row); the URL is the
    /// app bundle's file URL.
    public var onQuitApp: (URL) -> Void = { _ in }
    /// Open a link clip's URL in the browser (⌘K → Open Link on a link clip).
    public var onOpenClipLink: (URL) -> Void = { _ in }
    /// Only explicit scope/preview changes resize the window; result updates
    /// stay inside the existing scrolling viewport.
    public var onLayoutChanged: () -> Void = {}

    /// Bundle paths of apps macOS currently reports as running. `AppServices`
    /// snapshots `NSWorkspace.runningApplications` into this on summon and on
    /// change while the panel is visible, which drives `isSelectedAppRunning`
    /// and the "Switch to" / Quit actions. Empty in tests and previews that
    /// don't wire that snapshot up.
    public var runningAppPaths: Set<String> = []

    /// Rows pinned under every result list (the Spotify now-playing footer).
    /// Evaluated on each `setResults` pass, so it covers the empty-query recents
    /// branch, the instant pass, and the debounced splice with one seam — the
    /// row lands last (after the web row) in every query state.
    public var pinnedResults: () -> [LauncherResult] = { [] }

    private let instantRouter: QueryRouter
    private let secondaryProviders: [any LauncherProvider]
    private var searchTask: Task<Void, Never>?
    /// Bumped by every `scheduleSearch` call; lets a cancelled task's deferred
    /// cleanup recognize it's stale instead of clobbering a newer task's state.
    private var searchGeneration = 0
    /// True between a keystroke and the first `setResults` for that query.
    /// The previous list stays on screen for continuity, but it belongs to an
    /// older query, so `perform` must not act on it — ↩ pressed in that window
    /// is dropped, exactly as it was when the list used to be blanked.
    private var resultsAreStale = false

    /// The instant pass's rows, cached so the debounced secondary pass can
    /// splice its own results in without redoing the (cheap but not free)
    /// instant router call.
    private var lastInstantResults: [LauncherResult] = []

    /// Keystrokes that need a secondary pass funnel through here; one
    /// long-lived consumer debounces them so fast typing doesn't fan out to
    /// FTS/clipboard queries on every character. House pattern: see
    /// `DrawerViewModel`'s `searchChannel`.
    private let secondaryChannel = AsyncChannel<Void>()
    private var secondaryDebounceTask: Task<Void, Never>?

    /// FTS match excerpts for the clip rows currently on screen, keyed by
    /// item id. Computed once per search pass (batched into a single store
    /// call) instead of per row, so typing doesn't fire dozens of concurrent
    /// SQLite calls — one per visible clip row, every keystroke.
    public private(set) var matchExcerpts: [String: String] = [:]

    /// Makes the keystroke-to-results pipeline visible in Instruments: the
    /// instant pass (apps/calc/web, every keystroke) and the debounced
    /// secondary pass (indexed files/clipboard FTS/snippets) each get their
    /// own interval. `SearchPerformanceTests` documents the ~30ms
    /// keystroke-to-results budget these intervals make visible. Signposts
    /// cost effectively nothing when no tracing session is attached.
    private let searchSignposter = OSSignposter(subsystem: "com.nickysemenza.overboard", category: "Search")

    /// Instant providers (apps) answer from memory and render on every
    /// keystroke alongside the calculator; secondary providers (files) run
    /// concurrently and merge without displacing a manual selection.
    public init(
        instantProviders: [any LauncherProvider] = [],
        secondaryProviders: [any LauncherProvider],
        commandProvider: CommandProvider = CommandProvider(),
        clipboardStore: ClipStore? = nil,
        // The "Ask AI" fallback row (after the web row). Default dark so
        // tests/previews don't light it up; AppServices injects the real gate.
        askAIProvider: AskAIProvider = AskAIProvider(isAvailable: { false }),
        // Zero in tests that need the secondary pass to land immediately.
        secondaryDebounceInterval: Duration = .milliseconds(120)
    ) {
        self.clipboardStore = clipboardStore
        self.history = Self.normalizedHistory(Defaults[.launcherSearchHistory])
        self.instantRouter = QueryRouter(
            providers: [commandProvider, CalculatorProvider()] + instantProviders
                + [WebSearchProvider(), askAIProvider]
        )
        self.secondaryProviders = secondaryProviders
        let channel = self.secondaryChannel
        let interval = secondaryDebounceInterval
        self.secondaryDebounceTask = Task { [weak self] in
            for await _ in channel.debounce(for: interval) {
                guard let self else { return }
                await self.runSecondaryPass()
            }
        }
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
        self.history = Self.normalizedHistory(Defaults[.launcherSearchHistory])
        if self.history != Defaults[.launcherSearchHistory] {
            Defaults[.launcherSearchHistory] = self.history
        }
        self.selectedIndex = 0
        self.showGeneration += 1
        self.scheduleSearch()
    }

    public func scheduleSearch(preserveSelection: Bool = false) {
        self.searchTask?.cancel()
        let query = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = self.scope
        if !preserveSelection {
            self.clipboardLimit = 200
            self.hasMoreClipboard = false
            // Deliberately not clearing `results` here: the stale list stays on
            // screen until the instant pass (`setResults` below) replaces it, so
            // fast typing doesn't flash the empty state between keystrokes.
            self.resultsAreStale = true
            self.userSelected = false
            self.selectedIndex = 0
            self.isPaletteOpen = false
        }
        self.statusMessage = nil
        self.isSearching = true
        // Each call claims a new generation so a task cancelled by a later
        // keystroke can't clear `isSearching` after a newer task has already
        // taken over (and possibly finished) — only the current generation's
        // exit is allowed to flip the flag back off.
        self.searchGeneration += 1
        let generation = self.searchGeneration
        if query.isEmpty, scope == .all {
            let recents = self.history.reversed().prefix(self.maxRecentRows).map { LauncherResult.recentSearch(query: $0) }
            self.setResults(recents, preserveSelection: preserveSelection)
            self.searchTask = Task {
                let apps = await self.instantRouter.results(for: "", scope: .apps)
                guard !Task.isCancelled else {
                    self.finishSearch(generation)
                    return
                }
                let counts = Defaults[.launcherItemUseCounts]
                let candidates = apps.filter { row in
                    if counts[row.id, default: 0] > 0 { return true }
                    if case let .app(_, url) = row { return self.runningAppPaths.contains(url.path) }
                    return false
                }
                let suggestions = self.sortByFrecency(candidates).prefix(6)
                self.setResults(Array(suggestions) + recents, preserveSelection: true)
                self.finishSearch(generation)
            }
            return
        }
        self.searchTask = Task {
            // The clipboard-scope store query is itself a "secondary" pass (a
            // full FTS/browse query, not an in-memory lookup), so it's routed
            // through the same debounce as the file/clipboard/snippet
            // fan-out below. `isSearching` stays true — cleared by
            // `runSecondaryPass` once the debounced fetch lands — and
            // `resultsAreStale` (set above) keeps ↩ from acting on the old
            // list until then.
            if scope == .clipboard, self.clipboardStore != nil {
                await self.secondaryChannel.send(())
                return
            }
            let instantState = self.searchSignposter.beginInterval("instant pass")
            let instant = await self.instantRouter.results(for: query, scope: scope)
            self.searchSignposter.endInterval("instant pass", instantState)
            guard !Task.isCancelled else {
                self.finishSearch(generation)
                return
            }
            self.lastInstantResults = instant
            self.setResults(instant, preserveSelection: true)
            // The instant pass never carries `.clip` rows, so any excerpts
            // left over from the previous query no longer pair with anything
            // on screen; the debounced pass repopulates this once its own
            // clip rows land.
            self.matchExcerpts = [:]
            let providers = self.secondaryProviders.filter { $0.searchScopes.contains(scope) }
            guard !query.hasPrefix(":"), !providers.isEmpty else {
                self.finishSearch(generation)
                return
            }
            // Secondary providers (indexed files FTS, clipboard FTS, snippet
            // scans) don't run on every keystroke — only once the query has
            // been stable for the debounce interval passed to `init`.
            await self.secondaryChannel.send(())
        }
    }

    /// The debounced half of a search: the clipboard-scope store query, or
    /// the secondary-provider fan-out (indexed files FTS, clipboard FTS,
    /// snippet scans). Runs on the long-lived consumer started in `init`, so
    /// it isn't tied to `searchTask`'s per-keystroke cancellation — instead it
    /// reads the *current* query/scope when the debounce settles (matching
    /// `AsyncChannel.debounce`'s coalescing: only the latest keystroke's send
    /// actually fires this) and checks `searchGeneration` before touching
    /// `results`, so a pass superseded by a still-newer keystroke can't
    /// clobber it.
    private func runSecondaryPass() async {
        let generation = self.searchGeneration
        let state = self.searchSignposter.beginInterval("secondary pass")
        defer { self.searchSignposter.endInterval("secondary pass", state) }
        let query = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = self.scope
        if scope == .clipboard, let store = self.clipboardStore {
            do {
                let items = try await store.browseHistory(query, filter: self.clipboardFilter, limit: self.clipboardLimit + 1)
                let stats = try await store.libraryStats(topSources: 100)
                guard self.searchGeneration == generation else { return }
                self.sources = stats.bySource.map(\.app).sorted()
                self.hasMoreClipboard = items.count > self.clipboardLimit
                let clips = Array(items.prefix(self.clipboardLimit))
                self.setResults(clips.map(LauncherResult.clip), preserveSelection: true)
                await self.refreshMatchExcerpts(itemIDs: clips.map(\.id), query: query)
            } catch {
                guard self.searchGeneration == generation else { return }
                self.statusMessage = "Couldn’t search clipboard history. Try again."
                self.setResults([])
            }
            self.finishSearch(generation)
            return
        }
        let instant = self.lastInstantResults
        let providers = self.secondaryProviders.filter { $0.searchScopes.contains(scope) }
        // Re-checked here (not just in `scheduleSearch`, before the send):
        // a command-mode query that arrives while an older, non-command
        // send is still sitting in the debounce window must not let that
        // stale send fan out to secondary providers once it fires.
        guard !query.hasPrefix(":"), !providers.isEmpty else {
            self.finishSearch(generation)
            return
        }
        var buckets = [[LauncherResult]](repeating: [], count: providers.count)
        await withTaskGroup(of: (Int, [LauncherResult]).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask { await (index, provider.results(for: query)) }
            }
            for await (index, rows) in group {
                guard self.searchGeneration == generation else { return }
                buckets[index] = rows.filter(scope.includes)
                self.setResults(instant + buckets.flatMap(\.self), preserveSelection: true)
            }
        }
        guard self.searchGeneration == generation else { return }
        await self.refreshMatchExcerpts(for: self.results, query: query)
        self.finishSearch(generation)
    }

    /// Batches the FTS excerpts for every `.clip` row currently on screen into
    /// one store call instead of one per row — `LauncherRow` used to run
    /// `store.matchExcerpt` from its own per-row `.task`, firing dozens of
    /// concurrent SQLite calls while typing.
    private func refreshMatchExcerpts(for results: [LauncherResult], query: String) async {
        let ids = results.compactMap { result -> String? in
            guard case let .clip(item) = result else { return nil }
            return item.id
        }
        await self.refreshMatchExcerpts(itemIDs: ids, query: query)
    }

    private func refreshMatchExcerpts(itemIDs: [String], query: String) async {
        guard !itemIDs.isEmpty, !query.isEmpty, let store = self.clipboardStore else {
            self.matchExcerpts = [:]
            return
        }
        self.matchExcerpts = await (try? store.matchExcerpts(itemIDs: itemIDs, query: query)) ?? [:]
    }

    /// Clears `isSearching` only if no newer `scheduleSearch` call has started
    /// since this task began — a stale, cancelled task must never clear the
    /// spinner out from under a search that superseded it.
    private func finishSearch(_ generation: Int) {
        guard self.searchGeneration == generation else { return }
        self.isSearching = false
    }

    public func moveSelection(_ delta: Int) {
        guard !self.results.isEmpty else { return }
        self.select(at: min(max(self.selectedIndex + delta, 0), self.results.count - 1))
    }

    // MARK: - Search history

    /// Save the current query as the most-recent history entry. Called on every
    /// dismissal (commit / escape / click-outside); no-ops on empty queries.
    public func recordCurrentQuery() {
        let trimmed = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = BoundedRecents(mostRecentFirst: self.history.reversed(), limit: Self.maxHistory)
        updated.record(trimmed)
        self.history = Array(updated.mostRecentFirst.reversed())
        Defaults[.launcherSearchHistory] = self.history
    }

    /// Removes the selected recent-search row from history (⌘⌫ on the empty
    /// field). Returns true only when a recent was actually deleted, so the
    /// caller can swallow the keystroke; any other row kind is left untouched.
    @discardableResult
    public func deleteSelectedRecent() -> Bool {
        guard self.results.indices.contains(self.selectedIndex),
              case let .recentSearch(query) = self.results[self.selectedIndex]
        else { return false }
        var updated = BoundedRecents(mostRecentFirst: self.history.reversed(), limit: Self.maxHistory)
        updated.remove(query)
        self.history = Array(updated.mostRecentFirst.reversed())
        Defaults[.launcherSearchHistory] = self.history
        // Re-render the (still empty-field) recents list; setResults reclamps the
        // selection so it lands on the next row down.
        let oldIndex = self.selectedIndex
        self.setResults(
            self.results.filter { if case .app = $0 { true } else { false } }
                + self.history.reversed().prefix(self.maxRecentRows).map { .recentSearch(query: $0) }
        )
        self.selectedIndex = min(oldIndex, max(self.results.count - 1, 0))
        return true
    }

    // MARK: - Commit / actions

    /// Actions available for the currently-selected row, in footer/palette
    /// order (index 0/1/2 = ↩/⌘↩/⌥↩). Empty when nothing is selected.
    public var selectedActions: [LauncherAction] {
        guard self.results.indices.contains(self.selectedIndex) else { return [] }
        return LauncherActions.actions(for: self.results[self.selectedIndex], context: self.actionContext)
    }

    /// Actions for an arbitrary row, not just the selected one — powers each
    /// row's VoiceOver accessibility actions (a non-selected row must still
    /// list what it can do), sharing `selectedActions`' running-app context
    /// rule for app rows.
    public func actions(for result: LauncherResult) -> [LauncherAction] {
        let isRunning: Bool = if case let .app(_, url) = result { self.runningAppPaths.contains(url.path) } else { false }
        return LauncherActions.actions(for: result, context: LauncherActionContext(isAppRunning: isRunning))
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
        // Modifiers on rows with fewer actions fall back to ↩ — single-action
        // rows (web search, settings panes, commands) must not index past the
        // list, and snippet/calc ⌥↩ keeps its old alias-of-↩ behavior.
        let index: Int = switch modifier {
        case .none: 0
        case .command: actions.indices.contains(1) ? 1 : 0
        case .option: actions.indices.contains(2) ? 2 : 0
        }
        self.perform(actions[index])
    }

    /// Executes one action against the selected row. The single routing point
    /// for the footer's primary action, the ⌘K palette, and `commit`.
    public func perform(_ action: LauncherAction) {
        guard !self.resultsAreStale, self.results.indices.contains(self.selectedIndex) else { return }
        let result = self.results[self.selectedIndex]
        switch (action, result) {
        case let (.copy, .calculation(_, display)):
            self.onCopyText(display)
        case let (.paste, .calculation(_, display)):
            self.onPasteText(display)
        case let (.open, .app(_, url)), let (.switchTo, .app(_, url)):
            self.onOpenFile(url)
        case let (.open, .file(_, url, _)), let (.downloadAndOpen, .file(_, url, _)):
            self.onOpenFile(url)
        case (.preview, _):
            self.togglePreview()
        case let (.pin, .clip(item)), let (.unpin, .clip(item)):
            Task {
                try? await self.clipboardStore?.setPinned(id: item.id, !item.isPinned)
                self.scheduleSearch(preserveSelection: true)
            }
        case let (.openSource, .clip(item)):
            if let source = item.sourceURL, let url = URL(string: source) { self.onOpenClipLink(url) }
        case let (.revealInFinder, .app(_, url)), let (.revealInFinder, .file(_, url, _)):
            self.onRevealFile(url)
        case let (.copyPath, .app(_, url)), let (.copyPath, .file(_, url, _)):
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
        case let (.paste, .askAI(prompt)):
            self.onAskAI(prompt, .paste)
        case let (.copy, .askAI(prompt)):
            self.onAskAI(prompt, .copy)
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
            self.userSelected = true
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

    public func recordSuccessfulSelection(id: String, query: String) {
        var counts = Defaults[.launcherItemUseCounts]
        var lastUsed = Defaults[.launcherItemLastUsed]
        counts[id] = min(counts[id, default: 0] + 1, 100_000)
        lastUsed[id] = Date.now.timeIntervalSince1970
        if counts.count > 2000 {
            for key in counts.keys.sorted(by: { lastUsed[$0, default: 0] < lastUsed[$1, default: 0] }).prefix(counts.count - 2000) {
                counts.removeValue(forKey: key)
                lastUsed.removeValue(forKey: key)
            }
        }
        Defaults[.launcherItemUseCounts] = counts
        Defaults[.launcherItemLastUsed] = lastUsed
        let query = AppMatcher.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return }
        var usage = Defaults[.launcherSelectionUsage]
        let key = query + "\u{1F}" + id
        usage[key] = min(usage[key, default: 0] + 1, 100)
        if usage.count > 2000 {
            let oldest = usage.sorted { $0.value < $1.value }.prefix(usage.count - 2000)
            for entry in oldest {
                usage.removeValue(forKey: entry.key)
            }
        }
        Defaults[.launcherSelectionUsage] = usage
    }

    private func sortByFrecency(_ rows: [LauncherResult]) -> [LauncherResult] {
        LauncherFrecency.sorted(rows, counts: Defaults[.launcherItemUseCounts], lastUsed: Defaults[.launcherItemLastUsed])
    }

    private static func normalizedHistory(_ persisted: [String]) -> [String] {
        Array(BoundedRecents(mostRecentFirst: persisted.reversed(), limit: LauncherViewModel.maxHistory).mostRecentFirst.reversed())
    }

    private func setResults(_ newResults: [LauncherResult], preserveSelection: Bool = false) {
        // Only a manual selection is re-anchored by id. An automatic
        // selection deliberately snaps back to row 0 when a later provider
        // bucket re-sorts the list: the product rule is "the best match is
        // first and selected", so a file that outranks the instant web row
        // must be what ↩ opens. The 120 ms secondary-pass debounce is what
        // keeps that re-sort from racing a keypress.
        let anchor = preserveSelection && self.userSelected ? self.selectedResult?.id : nil
        let prefix = AppMatcher.fold(self.query.trimmingCharacters(in: .whitespacesAndNewlines)) + "\u{1F}"
        let usage = Dictionary(uniqueKeysWithValues: Defaults[.launcherSelectionUsage].compactMap { key, value in
            key.hasPrefix(prefix) ? (String(key.dropFirst(prefix.count)), value) : nil
        })
        let combined: [LauncherResult] = if self.scope == .clipboard {
            // The store owns FTS/OCR relevance and chronological browsing.
            newResults
        } else if self.query.isEmpty, self.scope == .apps {
            self.sortByFrecency(newResults)
        } else if self.query.isEmpty {
            newResults + (self.scope == .all ? self.pinnedResults() : [])
        } else {
            LauncherRanking.sorted(newResults + (self.scope == .all ? self.pinnedResults() : []), query: self.query,
                                   aliases: AppMatcher.parseAliases(Defaults[.launcherAppAliases]), usage: usage)
        }
        var seen = Set<String>()
        self.results = combined.filter { seen.insert($0.id).inserted }
        self.resultsAreStale = false
        if let anchor, let index = self.results.firstIndex(where: { $0.id == anchor }) {
            self.selectedIndex = index
        } else {
            self.selectedIndex = 0
        }
    }
}
