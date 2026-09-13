import Foundation
import OverboardCore
import OverboardMac
@testable import OverboardUI
import Testing

/// Pure logic, no snapshots — runs on CI too. App/file/command/system-setting
/// routing, plus the secondary-provider splice and `prepareForShow`. Split
/// out of `LauncherCommitRoutingTests` by routed result kind.
@Suite(.serialized)
@MainActor
struct LauncherCommitRoutingFileTests {
    @Test func performRoutesAppActions() async {
        let url = URL(fileURLWithPath: "/Applications/Notes.app")
        let viewModel = await LauncherCommitRoutingFixtures.makeViewModel(rows: [.app(name: "Notes", url: url)])

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
        // `settle()` covers the 120 ms debounce: the secondary pass is what
        // clears `isSearching` for this generation.
        await viewModel.settle()

        #expect(viewModel.results[0] == .snippet(snippet))
        #expect(viewModel.results[1] == .clip(clip))
        guard case .webSearch = viewModel.results[2] else {
            Issue.record("expected the web row last, got \(viewModel.results)")
            return
        }
    }

    @Test func commandRowRoutesToRunCommand() async {
        let viewModel = await LauncherCommitRoutingFixtures.makeViewModel(rows: [.command(.version)])

        var ran: [LauncherCommand] = []
        viewModel.onRunCommand = { ran.append($0) }

        viewModel.commit()

        #expect(ran == [.version])
    }

    /// ⌘↩ on a single-action row must fall back to the primary action rather
    /// than index past the action list (regression: crashed on web-search rows).
    @Test func commandModifierOnSingleActionRowFallsBackToPrimary() async throws {
        let url = try #require(URL(string: "https://example.com/search?q=zzz"))
        let viewModel = await LauncherCommitRoutingFixtures.makeViewModel(rows: [.webSearch(query: "zzz", url: url)])

        var opened: [URL] = []
        viewModel.onOpenWebSearch = { opened.append($0) }

        viewModel.commit(modifier: .command)

        #expect(opened == [url])
    }

    /// A command row with a resolved subtitle still routes on the command, not
    /// the subtitle (e.g. the live `:stats` row).
    @Test func commandRowWithSubtitleRoutesToRunCommand() async {
        let viewModel = await LauncherCommitRoutingFixtures.makeViewModel(
            rows: [.command(.stats, subtitle: "42 items")]
        )

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
        await viewModel.settle()
        // Not a wait for completion — `settle()` already covered that. This is
        // a window in which a wrongly-scheduled debounce would have fired and
        // spliced the clip in, which is the whole point of the test.
        try? await Task.sleep(for: .milliseconds(300))

        #expect(viewModel.results == [.command(.version)])
    }

    @Test func systemSettingRowRoutesToOpen() async throws {
        let url = try #require(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension"))
        let viewModel = await LauncherCommitRoutingFixtures.makeViewModel(
            rows: [.systemSetting(name: "Displays", url: url)]
        )

        var opened: [URL] = []
        viewModel.onOpenSystemSetting = { opened.append($0) }

        viewModel.commit()

        #expect(opened == [url])
    }

    /// Reopening the launcher keeps the prior query (cursor resumes there) and
    /// repopulates its rows instead of clearing to a blank bar.
    @Test func prepareForShowPreservesQueryAndResults() async {
        let viewModel = await LauncherCommitRoutingFixtures.makeViewModel(rows: [.command(.version)])
        #expect(viewModel.query == "zzz")

        viewModel.prepareForShow(clearQuery: false)
        #expect(viewModel.query == "zzz")
        await viewModel.settle()
        // Rows repopulate from the preserved query (instant router also appends
        // its standing web-search row).
        #expect(viewModel.results.first == .command(.version))
    }

    /// A stale reopen (`clearQuery: true`) with no history opens to a blank bar.
    @Test func prepareForShowClearingResetsQueryAndResults() async {
        Defaults[.launcherSearchHistory] = []
        let viewModel = await LauncherCommitRoutingFixtures.makeViewModel(rows: [.command(.version)])

        viewModel.prepareForShow(clearQuery: true)
        await viewModel.settle()

        #expect(viewModel.query.isEmpty)
        #expect(viewModel.results.isEmpty)
    }
}
