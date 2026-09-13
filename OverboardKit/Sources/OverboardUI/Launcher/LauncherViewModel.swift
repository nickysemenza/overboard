import AsyncAlgorithms
import Foundation
import Observation
import os
import OverboardCore
import OverboardMac

/// State machine for the launcher bar: instant calculator/web rows on every
/// keystroke, indexed file rows merged by relevance as they arrive.
///
/// The implementation is split across extensions in this directory:
/// `LauncherViewModel+Search.swift` (the keystroke-to-results pipeline and
/// search history), `LauncherViewModel+Commit.swift` (row actions and
/// `perform`/`commit`), and `LauncherViewModel+Palette.swift` (the ⌘K action
/// palette). Several stored properties below are `internal` rather than
/// `private` purely so those extensions — in other files — can read/write
/// them; none of that widening reaches past this module's public API.
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
    public internal(set) var results: [LauncherResult] = []
    public var selectedIndex = 0
    public var scope: LauncherScope = .all
    public var clipboardFilter = ClipboardFilter()
    public internal(set) var sources: [String] = []
    public internal(set) var hasMoreClipboard = false
    var clipboardLimit = 200
    public var targetAppName = "previous app"
    public var isPreviewVisible = false
    public var statusMessage: String?
    public internal(set) var isSearching = false
    var userSelected = false
    let clipboardStore: ClipStore?
    private var observationTask: Task<Void, Never>?

    public var selectedResult: LauncherResult? {
        self.results.indices.contains(self.selectedIndex) ? self.results[self.selectedIndex] : nil
    }

    public var showsPreview: Bool {
        self.scope == .clipboard || self.isPreviewVisible
    }

    public var primaryActionLabel: String? {
        guard let action = self.primaryAction else { return nil }
        if action == .paste {
            return "Paste to \(self.targetAppName)"
        }
        if action == .search {
            return "Search Google"
        }
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
        // A cancelled task never reaches `finishSearch`, so release anything
        // parked in `settle()` and don't leave the spinner flag stuck on a
        // hidden panel; `prepareForShow` re-arms it on the next summon.
        self.finishSearch(self.searchGeneration)
    }

    public func moveSelection(_ delta: Int) {
        guard !self.results.isEmpty else { return }
        self.select(at: min(max(self.selectedIndex + delta, 0), self.results.count - 1))
    }

    /// Bumped on every summon so the view re-asserts text-field focus
    /// (onAppear only fires once — the hosting view is reused).
    public internal(set) var showGeneration = 0

    /// Recent searches, most-recent last; persisted across launches. Surfaced as
    /// the result rows when the field is empty.
    public internal(set) var history: [String] = Defaults[.launcherSearchHistory]
    static let maxHistory = 20
    /// How many recents to actually show on an empty field — a short hint, not a
    /// full history dump that fills the panel.
    let maxRecentRows = 3

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

    let instantRouter: QueryRouter
    let secondaryProviders: [any LauncherProvider]
    var searchTask: Task<Void, Never>?
    /// Bumped by every `scheduleSearch` call; lets a cancelled task's deferred
    /// cleanup recognize it's stale instead of clobbering a newer task's state.
    var searchGeneration = 0
    /// True between a keystroke and the first `setResults` for that query.
    /// The previous list stays on screen for continuity, but it belongs to an
    /// older query, so `perform` must not act on it — ↩ pressed in that window
    /// is dropped, exactly as it was when the list used to be blanked.
    var resultsAreStale = false

    /// The instant pass's rows, cached so the debounced secondary pass can
    /// splice its own results in without redoing the (cheap but not free)
    /// instant router call.
    var lastInstantResults: [LauncherResult] = []

    /// Keystrokes that need a secondary pass funnel through here; one
    /// long-lived consumer debounces them so fast typing doesn't fan out to
    /// FTS/clipboard queries on every character. House pattern: see
    /// `DrawerViewModel`'s `searchChannel` — including the detail that the
    /// send runs on its own short-lived `Task`, never on `searchTask`:
    /// `AsyncChannel.send` drops the value when its task is cancelled, and a
    /// send parked behind a busy consumer would otherwise vanish on the next
    /// keystroke (or on `stopObserving`), leaving `isSearching` stuck.
    let secondaryChannel = AsyncChannel<Void>()
    private var secondaryDebounceTask: Task<Void, Never>?

    /// FTS match excerpts for the clip rows currently on screen, keyed by
    /// item id. Computed once per search pass (batched into a single store
    /// call) instead of per row, so typing doesn't fire dozens of concurrent
    /// SQLite calls — one per visible clip row, every keystroke.
    public internal(set) var matchExcerpts: [String: String] = [:]

    /// Makes the keystroke-to-results pipeline visible in Instruments: the
    /// instant pass (apps/calc/web, every keystroke) and the debounced
    /// secondary pass (indexed files/clipboard FTS/snippet scans) each get their
    /// own interval. `SearchPerformanceTests` documents the ~30ms
    /// keystroke-to-results budget these intervals make visible. Signposts
    /// cost effectively nothing when no tracing session is attached.
    let searchSignposter = OSSignposter(subsystem: "com.nickysemenza.overboard", category: "Search")

    /// Parked `settle()` callers, resumed by `finishSearch`. A list rather than
    /// a single continuation because several waiters can be outstanding.
    var settleWaiters: [CheckedContinuation<Void, Never>] = []

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

    // MARK: - ⌘K action palette

    //
    // (Stored properties only — the palette's behavior lives in
    // `LauncherViewModel+Palette.swift`; these have to stay here because
    // extensions can't declare stored properties.)

    public internal(set) var isPaletteOpen = false
    public var paletteQuery: String = ""
    public var paletteIndex: Int = 0
}
