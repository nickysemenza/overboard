import Foundation
import OverboardCore
import OverboardMac
@testable import OverboardUI
import Testing

private struct StubProvider: LauncherProvider {
    let rows: [LauncherResult]
    func results(for _: String) async -> [LauncherResult] {
        self.rows
    }
}

/// Pure logic, no snapshots — runs on CI too. Serialized because the history
/// tests share the process-wide `Defaults[.launcherSearchHistory]` key.
@Suite(.serialized)
@MainActor
struct LauncherCommitRoutingTests {
    private func makeViewModel(rows: [LauncherResult]) async -> LauncherViewModel {
        let viewModel = LauncherViewModel(
            instantProviders: [StubProvider(rows: rows)],
            secondaryProviders: []
        )
        viewModel.query = "zzz"
        viewModel.scheduleSearch()
        while viewModel.results.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return viewModel
    }

    @Test func clipRowRoutesPerModifier() async {
        let item = Fixtures.item(preview: "deploy checklist")
        let viewModel = await makeViewModel(rows: [.clip(item)])

        var pasted: [(String, PasteMode)] = []
        var copied: [String] = []
        viewModel.onPasteClip = { pasted.append(($0.id, $1)) }
        viewModel.onCopyClip = { copied.append($0.id) }

        viewModel.commit()
        viewModel.commit(modifier: .option)
        viewModel.commit(modifier: .command)

        #expect(pasted.map(\.0) == [item.id, item.id])
        #expect(pasted.map(\.1) == [.full, .plainText])
        #expect(copied == [item.id])
    }

    // MARK: - perform(_:) routing

    @Test func performRoutesAppActions() async {
        let url = URL(fileURLWithPath: "/Applications/Notes.app")
        let viewModel = await makeViewModel(rows: [.app(name: "Notes", url: url)])

        var opened: [URL] = []
        var revealed: [URL] = []
        var copiedPaths: [String] = []
        var quit: [URL] = []
        viewModel.onOpenFile = { opened.append($0) }
        viewModel.onRevealFile = { revealed.append($0) }
        viewModel.onCopyPath = { copiedPaths.append($0) }
        viewModel.onQuitApp = { quit.append($0) }

        viewModel.perform(.open)
        viewModel.perform(.switchTo)
        viewModel.perform(.revealInFinder)
        viewModel.perform(.copyPath)
        viewModel.perform(.quitApp)

        #expect(opened == [url, url]) // open + switchTo both raise the app
        #expect(revealed == [url])
        #expect(copiedPaths == [url.path])
        #expect(quit == [url])
    }

    @Test func performOpensLinkClip() async {
        let item = Fixtures.item(kind: .link, preview: " https://example.com ")
        let viewModel = await makeViewModel(rows: [.clip(item)])

        var opened: [URL] = []
        viewModel.onOpenClipLink = { opened.append($0) }

        viewModel.perform(.openLink)

        #expect(opened == [URL(string: "https://example.com")])
    }

    /// A whitespace-only link clip yields no open — the URL parse fails safely
    /// (matches `ClipAction.openLink`'s permissive `URL(string:)` behavior).
    @Test func performIgnoresBlankClipLink() async {
        let item = Fixtures.item(kind: .link, preview: "   ")
        let viewModel = await makeViewModel(rows: [.clip(item)])

        var opened = false
        viewModel.onOpenClipLink = { _ in opened = true }
        viewModel.perform(.openLink)

        #expect(!opened)
    }

    /// ⌘↩ on a recent-search row removes it (the second, palette-only-in-position
    /// action), while ↩ still re-runs it.
    @Test func commandOnRecentRemovesIt() {
        Defaults[.launcherSearchHistory] = []
        let viewModel = self.freshViewModel()
        for query in ["one", "two"] {
            viewModel.query = query
            viewModel.recordCurrentQuery()
        }
        viewModel.query = ""
        viewModel.scheduleSearch()
        // Rows: [two, one]. ⌘↩ on "two" removes it.
        viewModel.selectedIndex = 0
        viewModel.commit(modifier: .command)

        #expect(viewModel.results == [.recentSearch(query: "one")])
        #expect(viewModel.history == ["one"])
    }

    @Test func secondaryRowsSpliceAboveWebRow() async {
        let snippet = Snippet(title: "Standup", body: "notes")
        let clip = Fixtures.item(preview: "deploy checklist")
        let viewModel = LauncherViewModel(
            instantProviders: [],
            secondaryProviders: [
                StubProvider(rows: [.snippet(snippet)]),
                StubProvider(rows: [.clip(clip)]),
            ]
        )
        viewModel.query = "zzz"
        viewModel.scheduleSearch()
        // Secondary providers land after the 250 ms debounce.
        while viewModel.results.count < 3 {
            try? await Task.sleep(for: .milliseconds(25))
        }

        #expect(viewModel.results[0] == .snippet(snippet))
        #expect(viewModel.results[1] == .clip(clip))
        guard case .webSearch = viewModel.results[2] else {
            Issue.record("expected the web row last, got \(viewModel.results)")
            return
        }
    }

    @Test func commandRowRoutesToRunCommand() async {
        let viewModel = await makeViewModel(rows: [.command(.version)])

        var ran: [LauncherCommand] = []
        viewModel.onRunCommand = { ran.append($0) }

        viewModel.commit()

        #expect(ran == [.version])
    }

    /// ⌘↩ on a single-action row must fall back to the primary action rather
    /// than index past the action list (regression: crashed on web-search rows).
    @Test func commandModifierOnSingleActionRowFallsBackToPrimary() async {
        let url = URL(string: "https://example.com/search?q=zzz")!
        let viewModel = await makeViewModel(rows: [.webSearch(query: "zzz", url: url)])

        var opened: [URL] = []
        viewModel.onOpenWebSearch = { opened.append($0) }

        viewModel.commit(modifier: .command)

        #expect(opened == [url])
    }

    /// A command row with a resolved subtitle still routes on the command, not
    /// the subtitle (e.g. the live `:stats` row).
    @Test func commandRowWithSubtitleRoutesToRunCommand() async {
        let viewModel = await makeViewModel(rows: [.command(.stats, subtitle: "42 items")])

        var ran: [LauncherCommand] = []
        viewModel.onRunCommand = { ran.append($0) }

        viewModel.commit()

        #expect(ran == [.stats])
    }

    @Test func commandModeSkipsSecondaryRows() async {
        // ":"-queries are instant-only — no clip/file/Spotlight splice. The
        // command row itself comes from the real CommandProvider in the
        // instant router; the secondary clip below must never appear.
        let viewModel = LauncherViewModel(
            instantProviders: [],
            secondaryProviders: [StubProvider(rows: [.clip(Fixtures.item(preview: "x"))])]
        )
        viewModel.query = ":version"
        viewModel.scheduleSearch()
        while viewModel.results.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        // Give the (skipped) debounce window a chance to wrongly fire.
        try? await Task.sleep(for: .milliseconds(300))

        #expect(viewModel.results == [.command(.version)])
    }

    @Test func snippetRowRoutesPerModifier() async {
        let snippet = Snippet(title: "Standup", body: "Yesterday / Today")
        let viewModel = await makeViewModel(rows: [.snippet(snippet)])

        var pasted: [String] = []
        var copied: [String] = []
        viewModel.onPasteSnippet = { pasted.append($0.id) }
        viewModel.onCopySnippet = { copied.append($0.id) }

        viewModel.commit()
        viewModel.commit(modifier: .option) // same as ↩ for snippets
        viewModel.commit(modifier: .command)

        #expect(pasted == [snippet.id, snippet.id])
        #expect(copied == [snippet.id])
    }

    // MARK: - Spotify now-playing (pinned footer)

    private static let track = NowPlayingTrack(
        title: "Imagine", artist: "John Lennon", trackID: "spotify:track:abc123", state: .playing
    )

    /// The pinned row trails the list on a non-empty query, landing after the
    /// standing web row even once the debounced secondary providers splice in.
    @Test func nowPlayingPinsAfterWebRow() async {
        let clip = Fixtures.item(preview: "deploy checklist")
        let viewModel = LauncherViewModel(
            instantProviders: [],
            secondaryProviders: [StubProvider(rows: [.clip(clip)])]
        )
        viewModel.pinnedResults = { [.nowPlaying(Self.track)] }
        viewModel.query = "zzz"
        viewModel.scheduleSearch()
        // Wait for the debounced splice: clip + web + pinned now-playing.
        while viewModel.results.count < 3 {
            try? await Task.sleep(for: .milliseconds(25))
        }

        #expect(viewModel.results.last == .nowPlaying(Self.track))
        guard case .webSearch = viewModel.results[viewModel.results.count - 2] else {
            Issue.record("expected the web row directly before the pinned row, got \(viewModel.results)")
            return
        }
    }

    /// With recents, the pinned row is appended after them; with no history it
    /// stands alone and is selected by default so plain ↩ copies its link.
    @Test func nowPlayingShowsOnEmptyQuery() {
        let viewModel = self.freshViewModel()
        viewModel.pinnedResults = { [.nowPlaying(Self.track)] }

        for query in ["one", "two"] {
            viewModel.query = query
            viewModel.recordCurrentQuery()
        }
        viewModel.query = ""
        viewModel.scheduleSearch()
        #expect(viewModel.results == [
            .recentSearch(query: "two"),
            .recentSearch(query: "one"),
            .nowPlaying(Self.track),
        ])

        // With no history, the lone pinned row is the whole list and is
        // selected by default so plain ↩ copies the link.
        Defaults[.launcherSearchHistory] = []
        viewModel.prepareForShow(clearQuery: true) // reloads history from Defaults, re-runs empty
        #expect(viewModel.results == [.nowPlaying(Self.track)])
        #expect(viewModel.selectedIndex == 0)
    }

    @Test func nowPlayingRowRoutesPerModifier() async {
        let viewModel = await makeViewModel(rows: [.nowPlaying(Self.track)])

        var copied: [String] = []
        var opened: [String] = []
        viewModel.onCopyNowPlayingLink = { copied.append($0.trackID) }
        viewModel.onOpenSpotify = { opened.append($0.trackID) }

        viewModel.commit() // ↩ copies the link
        viewModel.commit(modifier: .option) // ⌥↩ same as ↩
        viewModel.commit(modifier: .command) // ⌘↩ opens Spotify

        #expect(copied == [Self.track.trackID, Self.track.trackID])
        #expect(opened == [Self.track.trackID])
    }

    @Test func systemSettingRowRoutesToOpen() async throws {
        let url = try #require(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension"))
        let viewModel = await makeViewModel(rows: [.systemSetting(name: "Displays", url: url)])

        var opened: [URL] = []
        viewModel.onOpenSystemSetting = { opened.append($0) }

        viewModel.commit()

        #expect(opened == [url])
    }

    /// Reopening the launcher keeps the prior query (cursor resumes there) and
    /// repopulates its rows instead of clearing to a blank bar.
    @Test func prepareForShowPreservesQueryAndResults() async {
        let viewModel = await makeViewModel(rows: [.command(.version)])
        #expect(viewModel.query == "zzz")

        viewModel.prepareForShow(clearQuery: false)
        #expect(viewModel.query == "zzz")
        while viewModel.results.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        // Rows repopulate from the preserved query (instant router also appends
        // its standing web-search row).
        #expect(viewModel.results.first == .command(.version))
    }

    /// A stale reopen (`clearQuery: true`) with no history opens to a blank bar.
    @Test func prepareForShowClearingResetsQueryAndResults() async {
        Defaults[.launcherSearchHistory] = []
        let viewModel = await makeViewModel(rows: [.command(.version)])

        viewModel.prepareForShow(clearQuery: true)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(viewModel.query.isEmpty)
        #expect(viewModel.results.isEmpty)
    }

    // MARK: - ⌘K palette

    @Test func paletteOpensFiltersAndRuns() async {
        let item = Fixtures.item(kind: .link, preview: "https://example.com")
        let viewModel = await makeViewModel(rows: [.clip(item)])

        // Opens only when a row with actions is selected.
        #expect(!viewModel.isPaletteOpen)
        viewModel.togglePalette()
        #expect(viewModel.isPaletteOpen)
        // Link clip actions: paste, copy, paste plain, open link.
        #expect(viewModel.filteredPaletteActions == [.paste, .copy, .pastePlain, .openLink])

        // Case-insensitive substring filter over the label.
        viewModel.paletteQuery = "LINK"
        #expect(viewModel.filteredPaletteActions == [.openLink])

        // Running the filtered action closes the palette and fires the effect.
        var opened: [URL] = []
        viewModel.onOpenClipLink = { opened.append($0) }
        viewModel.paletteIndex = 0
        viewModel.runPaletteAction()

        #expect(!viewModel.isPaletteOpen)
        #expect(opened == [URL(string: "https://example.com")])
    }

    @Test func paletteSelectionClampsToFilteredCount() async {
        let viewModel = await makeViewModel(rows: [.clip(Fixtures.item(preview: "x"))])
        viewModel.togglePalette()
        // Three actions for a text clip; ↓ past the end clamps to the last.
        viewModel.movePaletteSelection(1)
        viewModel.movePaletteSelection(1)
        viewModel.movePaletteSelection(1)
        #expect(viewModel.paletteIndex == 2)
        viewModel.movePaletteSelection(-5)
        #expect(viewModel.paletteIndex == 0)
    }

    @Test func togglePaletteClosesWhenAlreadyOpen() async {
        let viewModel = await makeViewModel(rows: [.command(.version)])
        viewModel.togglePalette()
        #expect(viewModel.isPaletteOpen)
        viewModel.togglePalette()
        #expect(!viewModel.isPaletteOpen)
    }

    // MARK: - Search history

    private func freshViewModel() -> LauncherViewModel {
        Defaults[.launcherSearchHistory] = []
        return LauncherViewModel(instantProviders: [], secondaryProviders: [])
    }

    /// Recording de-dupes (moves an existing entry to most-recent) and persists.
    @Test func recordDeDupesAndPersists() {
        let viewModel = self.freshViewModel()

        for query in ["alpha", "beta", "alpha"] {
            viewModel.query = query
            viewModel.recordCurrentQuery()
        }

        #expect(viewModel.history == ["beta", "alpha"])
        #expect(Defaults[.launcherSearchHistory] == ["beta", "alpha"])
    }

    /// Empty/whitespace queries never enter history.
    @Test func recordIgnoresBlankQuery() {
        let viewModel = self.freshViewModel()
        viewModel.query = "   "
        viewModel.recordCurrentQuery()
        #expect(viewModel.history.isEmpty)
    }

    /// History is capped to the most-recent `maxHistory` entries.
    @Test func recordCapsHistory() {
        let viewModel = self.freshViewModel()
        for index in 0 ..< 25 {
            viewModel.query = "q\(index)"
            viewModel.recordCurrentQuery()
        }
        #expect(viewModel.history.count == 20)
        #expect(viewModel.history.first == "q5")
        #expect(viewModel.history.last == "q24")
    }

    /// An empty field lists recent searches as rows, most-recent first.
    @Test func emptyFieldListsRecentSearches() {
        let viewModel = self.freshViewModel()
        for query in ["one", "two", "three"] {
            viewModel.query = query
            viewModel.recordCurrentQuery()
        }

        viewModel.query = ""
        viewModel.scheduleSearch()

        #expect(viewModel.results == [
            .recentSearch(query: "three"),
            .recentSearch(query: "two"),
            .recentSearch(query: "one"),
        ])
    }

    /// The empty field shows only a short list of the most recent searches, not
    /// the whole stored history — it's a hint, not a panel-filling dump.
    @Test func emptyFieldCapsRecentSearchesShown() {
        let viewModel = self.freshViewModel()
        for index in 0 ..< 12 {
            viewModel.query = "q\(index)"
            viewModel.recordCurrentQuery()
        }

        viewModel.query = ""
        viewModel.scheduleSearch()

        #expect(viewModel.results.count == 3)
        // Most-recent first: q11 down to q9.
        #expect(viewModel.results.first == .recentSearch(query: "q11"))
        #expect(viewModel.results.last == .recentSearch(query: "q9"))
    }

    @Test func deleteSelectedRecentRemovesItFromHistory() {
        let viewModel = self.freshViewModel()
        for query in ["one", "two", "three"] {
            viewModel.query = query
            viewModel.recordCurrentQuery()
        }
        viewModel.query = ""
        viewModel.scheduleSearch()

        // Rows are most-recent first: [three, two, one]. Delete "two".
        viewModel.selectedIndex = 1
        #expect(viewModel.deleteSelectedRecent())

        #expect(viewModel.results == [.recentSearch(query: "three"), .recentSearch(query: "one")])
        #expect(viewModel.history == ["one", "three"])
        #expect(Defaults[.launcherSearchHistory] == ["one", "three"])
        // Selection stays valid, landing on the row that shifted up.
        #expect(viewModel.selectedIndex == 1)
    }

    @Test func deleteSelectedRecentNoOpsWithoutRecents() {
        let viewModel = self.freshViewModel()
        viewModel.query = ""
        viewModel.scheduleSearch()
        // No history → empty recents list → nothing to delete.
        #expect(viewModel.results.isEmpty)
        #expect(!viewModel.deleteSelectedRecent())
    }

    /// Committing a recents row refills the bar and re-runs that search in place
    /// (no dismiss, no row action fired).
    @Test func committingRecentSearchReRunsInPlace() async {
        Defaults[.launcherSearchHistory] = []
        let app = LauncherResult.app(name: "Notes", url: URL(fileURLWithPath: "/Applications/Notes.app"))
        let viewModel = LauncherViewModel(
            instantProviders: [StubProvider(rows: [app])],
            secondaryProviders: []
        )

        viewModel.query = "foo"
        viewModel.recordCurrentQuery()
        viewModel.query = ""
        viewModel.scheduleSearch()
        #expect(viewModel.results == [.recentSearch(query: "foo")])

        var opened = false
        viewModel.onOpenFile = { _ in opened = true }
        viewModel.commit() // selection 0 is the recents row

        #expect(viewModel.query == "foo")
        while viewModel.results.contains(where: { if case .recentSearch = $0 { true } else { false } }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.results.contains(app))
        #expect(!opened) // re-running a recent must not commit a row
    }
}
