import Foundation
import OverboardCore
import OverboardMac
@testable import OverboardUI
import Testing

/// Pure logic, no snapshots — runs on CI too. Search history/recents routing,
/// plus the pinned Spotify now-playing footer and the Ask AI fallback row
/// (both of which pin relative to recents/the web row). Split out of
/// `LauncherCommitRoutingTests` by routed result kind. Serialized because the
/// history tests share the process-wide `Defaults[.launcherSearchHistory]` key.
@Suite(.serialized)
@MainActor
struct LauncherCommitRoutingHistoryTests {
    /// ⌘↩ on a recent-search row removes it (the second, palette-only-in-position
    /// action), while ↩ still re-runs it.
    @Test func commandOnRecentRemovesIt() {
        Defaults[.launcherSearchHistory] = []
        let viewModel = LauncherCommitRoutingFixtures.freshViewModel()
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

    @Test func legacySearchHistoryNormalizesWithoutChangingItsStoredOrder() {
        let viewModel = LauncherCommitRoutingFixtures.freshViewModel()
        Defaults[.launcherSearchHistory] = ["old", "middle", "old", "new"]

        viewModel.prepareForShow(clearQuery: true)

        #expect(viewModel.history == ["middle", "old", "new"])
        #expect(Defaults[.launcherSearchHistory] == ["middle", "old", "new"])
    }

    // MARK: - Spotify now-playing (pinned footer)

    /// The pinned row trails the list on a non-empty query, landing after the
    /// standing web row even once the debounced secondary providers splice in.
    @Test func nowPlayingPinsAfterWebRow() async {
        let clip = Fixtures.item(preview: "deploy checklist")
        let viewModel = LauncherViewModel(
            instantProviders: [],
            secondaryProviders: [StubProvider(rows: [.clip(clip)])]
        )
        viewModel.pinnedResults = { [.nowPlaying(LauncherCommitRoutingFixtures.track)] }
        viewModel.query = "zzz"
        viewModel.scheduleSearch()
        // The debounced splice lands before `settle()` returns: clip + web +
        // pinned now-playing.
        await viewModel.settle()

        #expect(viewModel.results.last == .nowPlaying(LauncherCommitRoutingFixtures.track))
        guard case .webSearch = viewModel.results[viewModel.results.count - 2] else {
            Issue.record("expected the web row directly before the pinned row, got \(viewModel.results)")
            return
        }
    }

    /// With recents, the pinned row is appended after them; with no history it
    /// stands alone and is selected by default so plain ↩ copies its link.
    @Test func nowPlayingShowsOnEmptyQuery() {
        let viewModel = LauncherCommitRoutingFixtures.freshViewModel()
        viewModel.pinnedResults = { [.nowPlaying(LauncherCommitRoutingFixtures.track)] }

        for query in ["one", "two"] {
            viewModel.query = query
            viewModel.recordCurrentQuery()
        }
        viewModel.query = ""
        viewModel.scheduleSearch()
        #expect(viewModel.results == [
            .recentSearch(query: "two"),
            .recentSearch(query: "one"),
            .nowPlaying(LauncherCommitRoutingFixtures.track),
        ])

        // With no history, the lone pinned row is the whole list and is
        // selected by default so plain ↩ copies the link.
        Defaults[.launcherSearchHistory] = []
        viewModel.prepareForShow(clearQuery: true) // reloads history from Defaults, re-runs empty
        #expect(viewModel.results == [.nowPlaying(LauncherCommitRoutingFixtures.track)])
        #expect(viewModel.selectedIndex == 0)
    }

    @Test func nowPlayingRowRoutesPerModifier() async {
        let viewModel = await LauncherCommitRoutingFixtures
            .makeViewModel(rows: [.nowPlaying(LauncherCommitRoutingFixtures.track)])

        var copied: [String] = []
        var opened: [String] = []
        viewModel.onCopyNowPlayingLink = { copied.append($0.trackID) }
        viewModel.onOpenSpotify = { opened.append($0.trackID) }

        viewModel.commit() // ↩ copies the link
        viewModel.commit(modifier: .option) // ⌥↩ same as ↩
        viewModel.commit(modifier: .command) // ⌘↩ opens Spotify

        #expect(copied == [LauncherCommitRoutingFixtures.track.trackID, LauncherCommitRoutingFixtures.track.trackID])
        #expect(opened == [LauncherCommitRoutingFixtures.track.trackID])
    }

    // MARK: - Ask AI fallback

    /// ↩ runs the prompt with paste delivery; ⌘↩ with copy delivery. ⌥↩ falls
    /// back to ↩ (paste) since askAI has only two actions.
    @Test func askAIRowRoutesPerModifier() async {
        let viewModel = await LauncherCommitRoutingFixtures.makeViewModel(rows: [.askAI(prompt: "make this concise")])

        var calls: [(String, LauncherViewModel.AskAIDelivery)] = []
        viewModel.onAskAI = { calls.append(($0, $1)) }

        viewModel.commit() // ↩ paste
        viewModel.commit(modifier: .command) // ⌘↩ copy
        viewModel.commit(modifier: .option) // ⌥↩ falls back to ↩ (paste)

        #expect(calls.map(\.0) == ["make this concise", "make this concise", "make this concise"])
        #expect(calls.map(\.1) == [.paste, .copy, .paste])
    }

    /// The Ask AI row pins after the web row (and below the debounced secondary
    /// rows), above the pinned now-playing footer.
    @Test func askAIPinsAfterWebRowAndBeforeNowPlaying() async {
        let clip = Fixtures.item(preview: "deploy checklist")
        let viewModel = LauncherViewModel(
            instantProviders: [],
            secondaryProviders: [StubProvider(rows: [.clip(clip)])],
            askAIProvider: AskAIProvider(isAvailable: { true })
        )
        viewModel.pinnedResults = { [.nowPlaying(LauncherCommitRoutingFixtures.track)] }
        viewModel.query = "make this shorter"
        viewModel.scheduleSearch()
        // The debounced splice lands before `settle()` returns: clip + web +
        // askAI + pinned now-playing.
        await viewModel.settle()

        // clip (secondary), then web, then askAI, then the pinned footer last.
        #expect(viewModel.results[0] == .clip(clip))
        guard case .webSearch = viewModel.results[1] else {
            Issue.record("expected web row after the clip, got \(viewModel.results)")
            return
        }
        #expect(viewModel.results[2] == .askAI(prompt: "make this shorter"))
        #expect(viewModel.results.last == .nowPlaying(LauncherCommitRoutingFixtures.track))
    }

    // MARK: - Search history

    /// Recording de-dupes (moves an existing entry to most-recent) and persists.
    @Test func recordDeDupesAndPersists() {
        let viewModel = LauncherCommitRoutingFixtures.freshViewModel()

        for query in ["alpha", "beta", "alpha"] {
            viewModel.query = query
            viewModel.recordCurrentQuery()
        }

        #expect(viewModel.history == ["beta", "alpha"])
        #expect(Defaults[.launcherSearchHistory] == ["beta", "alpha"])
    }

    /// Empty/whitespace queries never enter history.
    @Test func recordIgnoresBlankQuery() {
        let viewModel = LauncherCommitRoutingFixtures.freshViewModel()
        viewModel.query = "   "
        viewModel.recordCurrentQuery()
        #expect(viewModel.history.isEmpty)
    }

    /// History is capped to the most-recent `maxHistory` entries.
    @Test func recordCapsHistory() {
        let viewModel = LauncherCommitRoutingFixtures.freshViewModel()
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
        let viewModel = LauncherCommitRoutingFixtures.freshViewModel()
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
        let viewModel = LauncherCommitRoutingFixtures.freshViewModel()
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
        let viewModel = LauncherCommitRoutingFixtures.freshViewModel()
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
        let viewModel = LauncherCommitRoutingFixtures.freshViewModel()
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
        await viewModel.settle()
        #expect(!viewModel.isSearching)
        #expect(viewModel.results.contains(app))
        #expect(!opened) // re-running a recent must not commit a row
    }
}
