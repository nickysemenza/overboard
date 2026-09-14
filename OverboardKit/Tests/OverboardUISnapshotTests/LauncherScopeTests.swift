import Foundation
import OverboardCore
import OverboardMac
@testable import OverboardUI
import Testing

private struct DelayedLauncherProvider: LauncherProvider {
    var rows: [LauncherResult]
    var delay: Duration = .zero

    func results(for _: String) async -> [LauncherResult] {
        try? await Task.sleep(for: self.delay)
        return self.rows
    }
}

/// Shared by both suites below — a struct's test body is kept under
/// SwiftLint's `type_body_length` budget by splitting the launcher-ranking
/// regression tests out into their own suite rather than growing this one.
@MainActor
private func waitForSearch(_ model: LauncherViewModel) async {
    await model.settle()
    #expect(!model.isSearching)
}

@Suite(.serialized)
@MainActor
struct LauncherScopeTests {
    @Test func firstSelectionTracksBestResultUntilUserNavigates() async {
        let file = LauncherResult.file(name: "hello.txt", url: URL(fileURLWithPath: "/tmp/hello.txt"))
        let model = LauncherViewModel(secondaryProviders: [
            DelayedLauncherProvider(
                rows: [file],
                delay: .milliseconds(40)
            ),
        ])
        model.query = "hello"
        model.scheduleSearch()
        await waitForSearch(model)
        #expect(model.selectedResult == file)
        var opened: URL?
        model.onOpenFile = { opened = $0 }
        model.commit()
        #expect(opened?.lastPathComponent == "hello.txt")
    }

    @Test func lateResultsCannotReplaceManualSelection() async {
        let app = LauncherResult.app(name: "Hello Helper", url: URL(fileURLWithPath: "/Applications/Hello Helper.app"))
        let file = LauncherResult.file(name: "hello.txt", url: URL(fileURLWithPath: "/tmp/hello.txt"))
        let model = LauncherViewModel(
            instantProviders: [DelayedLauncherProvider(rows: [app])],
            secondaryProviders: [DelayedLauncherProvider(rows: [file], delay: .milliseconds(80))]
        )
        model.query = "hello"
        model.scheduleSearch()
        // Deliberately *not* `settle()`: the point is to navigate while the
        // slow secondary provider is still in flight, and settling would wait
        // for exactly the results this test must select ahead of.
        for _ in 0 ..< 100 where model.results.count < 2 {
            try? await Task.sleep(for: .milliseconds(1))
        }
        model.moveSelection(1)
        let chosen = model.selectedResult
        await waitForSearch(model)
        #expect(model.results.first == file)
        #expect(model.selectedResult == chosen)
        var searched = false
        model.onOpenWebSearch = { _ in searched = true }
        model.commit()
        #expect(searched)
    }

    @Test func scopesKeepOnlyTheirOwnResultsAndAllKeepsExtras() async {
        let app = LauncherResult.app(name: "Notes", url: URL(fileURLWithPath: "/Applications/Notes.app"))
        let file = LauncherResult.file(name: "notes.txt", url: URL(fileURLWithPath: "/tmp/notes.txt"))
        let model = LauncherViewModel(
            instantProviders: [DelayedLauncherProvider(rows: [app, file])],
            secondaryProviders: []
        )
        model.query = "notes"
        model.setScope(.apps)
        await waitForSearch(model)
        #expect(model.results == [app])
        model.setScope(.files)
        await waitForSearch(model)
        #expect(model.results == [file])
        model.setScope(.all)
        await waitForSearch(model)
        #expect(model.results.contains(app) && model.results.contains(file))
        #expect(model.results.contains {
            if case .webSearch = $0 {
                true
            } else {
                false
            }
        })
    }

    @Test func successfulActionsFeedTheDefaultAppSuggestions() async {
        let oldCounts = Defaults[.launcherItemUseCounts]
        let oldDates = Defaults[.launcherItemLastUsed]
        let oldQueries = Defaults[.launcherSelectionUsage]
        defer {
            Defaults[.launcherItemUseCounts] = oldCounts
            Defaults[.launcherItemLastUsed] = oldDates
            Defaults[.launcherSelectionUsage] = oldQueries
        }
        Defaults[.launcherItemUseCounts] = [:]
        Defaults[.launcherItemLastUsed] = [:]
        let frequent = LauncherResult.app(name: "Frequent App", url: URL(fileURLWithPath: "/fixture/frequent.app"))
        let running = LauncherResult.app(name: "Running App", url: URL(fileURLWithPath: "/fixture/running.app"))
        let model = LauncherViewModel(
            instantProviders: [DelayedLauncherProvider(rows: [running, frequent])],
            secondaryProviders: []
        )
        model.runningAppPaths = ["/fixture/running.app"]
        model.scheduleSearch()
        await waitForSearch(model)
        #expect(model.results.first == running)
        #expect(Defaults[.launcherItemUseCounts].isEmpty)
        model.recordSuccessfulSelection(id: frequent.id, query: "")
        model.scheduleSearch()
        await waitForSearch(model)
        #expect(model.results.first == frequent)
        #expect(Defaults[.launcherItemUseCounts][frequent.id] == 1)
        model.setScope(.apps)
        await waitForSearch(model)
        #expect(model.results.first == frequent)
    }

    /// `scheduleSearch` deliberately stops clearing `results` synchronously on
    /// every keystroke (that used to flash the "No results" empty state
    /// between characters for a fast typist) — the previous list now stays on
    /// screen until the instant pass's `setResults` call replaces it.
    @Test func newQueryKeepsPreviousResultsVisibleUntilTheInstantPassReplacesThem() async {
        let file = LauncherResult.file(name: "hello.txt", url: URL(fileURLWithPath: "/tmp/hello.txt"))
        let model = LauncherViewModel(secondaryProviders: [
            DelayedLauncherProvider(
                rows: [file],
                delay: .milliseconds(30)
            ),
        ])
        model.query = "hello"
        model.scheduleSearch()
        await waitForSearch(model)
        #expect(!model.results.isEmpty)
        model.query = "completely different"
        model.scheduleSearch()
        // No await yet: the instant pass hasn't had a chance to run, so this
        // is the synchronous state right after the keystroke.
        #expect(!model.results.isEmpty)
        await waitForSearch(model)
        model.stopObserving()
    }

    @Test func clipboardPaginationKeepsSelectionAndFiltersResetThePage() async throws {
        let store = try Fixtures.store()
        for index in 0 ..< 205 {
            _ = try await store.ingest(PasteboardSnapshot(
                reps: [.init(uti: WellKnownUTI.plainText, data: Data("history entry \(index)".utf8))],
                sourceBundleID: nil,
                sourceAppName: nil
            ))
        }
        let model = LauncherViewModel(secondaryProviders: [], clipboardStore: store)
        model.setScope(.clipboard)
        await waitForSearch(model)
        #expect(model.results.count == 200 && model.hasMoreClipboard)
        model.select(at: 20)
        let selected = model.selectedResult?.id
        model.loadMoreClipboard()
        await waitForSearch(model)
        #expect(model.results.count == 205 && !model.hasMoreClipboard)
        #expect(model.selectedResult?.id == selected)
        model.clipboardFilter.kind = .image
        model.scheduleSearch()
        await waitForSearch(model)
        #expect(model.results.isEmpty && !model.hasMoreClipboard)
    }

    @Test func cloudResultOnlyDownloadsOnCommit() async {
        let cloud = LauncherResult.file(
            name: "budget.xlsx",
            url: URL(fileURLWithPath: "/fixture/budget.xlsx"),
            info: FileSearchInfo(availability: .cloud)
        )
        let model = LauncherViewModel(
            instantProviders: [DelayedLauncherProvider(rows: [cloud])],
            secondaryProviders: []
        )
        var opened = 0
        model.onOpenFile = { _ in opened += 1 }
        model.query = "budget"
        model.setScope(.files)
        await waitForSearch(model)
        model.select(at: 0)
        #expect(opened == 0)
        #expect(model.primaryActionLabel == "Download & Open")
        model.commit()
        #expect(opened == 1)
    }

    /// The stale list stays visible for continuity, but it belongs to the old
    /// query, so ↩ in the window before the instant pass lands must not act
    /// on it — same outcome as when the list used to be blanked.
    @Test func aNewQueryImmediatelyClearsAnOldAction() async {
        let file = LauncherResult.file(name: "hello.txt", url: URL(fileURLWithPath: "/tmp/hello.txt"))
        let model = LauncherViewModel(secondaryProviders: [
            DelayedLauncherProvider(
                rows: [file],
                delay: .milliseconds(30)
            ),
        ])
        model.query = "hello"
        model.scheduleSearch()
        await waitForSearch(model)
        var opened = false
        model.onOpenFile = { _ in opened = true }
        model.query = "completely different"
        model.scheduleSearch()
        model.commit()
        #expect(!opened)
        await waitForSearch(model)
        model.stopObserving()
    }

    /// Regression test for two related bugs in `scheduleSearch`: (1) it used
    /// to blank `results` synchronously on every keystroke, flashing the
    /// "No results" empty state for a fast typist, and (2) a search task
    /// cancelled by a newer keystroke could still clear `isSearching` after
    /// the newer task had already claimed (or finished) it, leaving the
    /// spinner stuck forever spinning or falsely idle. A slow instant
    /// provider stands in for real provider latency so each search stays
    /// in flight long enough to observe both fixes.
    /// Dismissing the panel cancels the search task, and a cancelled task never
    /// reaches `finishSearch` — `stopObserving` has to release `settle()`
    /// itself or a "type, Esc, settle" sequence parks forever.
    @Test(.timeLimit(.minutes(1))) func settleReturnsAfterStopObserving() async {
        let file = LauncherResult.file(name: "hello.txt", url: URL(fileURLWithPath: "/tmp/hello.txt"))
        let model = LauncherViewModel(secondaryProviders: [
            DelayedLauncherProvider(
                rows: [file],
                delay: .milliseconds(200)
            ),
        ])
        model.query = "hello"
        model.scheduleSearch()
        model.stopObserving()
        await model.settle()
        #expect(!model.isSearching)
    }

    @Test func rapidQueryChangesNeverFlashEmptyResultsAndClearTheSpinner() async {
        let terminal = LauncherResult.app(name: "Terminal", url: URL(fileURLWithPath: "/Applications/Terminal.app"))
        let model = LauncherViewModel(
            instantProviders: [DelayedLauncherProvider(rows: [terminal], delay: .milliseconds(20))],
            secondaryProviders: []
        )
        model.query = "t"
        model.scheduleSearch()
        await waitForSearch(model)
        #expect(!model.results.isEmpty)

        // A bounded poll is the simplest reliable way to sample `results`
        // between the rapid-fire keystrokes below; the view model exposes no
        // dedicated "did the list ever go empty" signal.
        var observedEmptyResults = false
        let observer = Task {
            while !Task.isCancelled {
                if model.results.isEmpty {
                    observedEmptyResults = true
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }

        // Three keystrokes back-to-back, each cancelling the previous
        // in-flight search before its slow instant provider resolves.
        model.query = "te"
        model.scheduleSearch()
        model.query = "ter"
        model.scheduleSearch()
        model.query = "term"
        model.scheduleSearch()

        await waitForSearch(model)
        observer.cancel()

        #expect(!observedEmptyResults)
        #expect(!model.isSearching)
        #expect(!model.results.isEmpty)
    }
}

/// Split out from `LauncherScopeTests` (only to stay under SwiftLint's
/// `type_body_length` budget): full-pipeline regression coverage for the
/// "sm" acronym-tier and per-query-usage ranking rules in `LauncherRanking`.
@Suite(.serialized)
@MainActor
struct LauncherRankingScopeTests {
    /// Regression test for the "sm" bug: Sublime Merge is an instant-pass
    /// acronym match (`.prefix` after the change), and must not be bumped
    /// down when the slower secondary pass lands prefix-matched files that
    /// used to tie (or beat) it on tier alone.
    @Test func acronymAppSurvivesLateFileResults() async {
        let app = LauncherResult.app(
            name: "Sublime Merge",
            url: URL(fileURLWithPath: "/Applications/Sublime Merge.app")
        )
        let smart = LauncherResult.file(name: "smart", url: URL(fileURLWithPath: "/tmp/smart"))
        let smime = LauncherResult.file(name: "smime", url: URL(fileURLWithPath: "/tmp/smime"))
        let model = LauncherViewModel(
            instantProviders: [DelayedLauncherProvider(rows: [app])],
            secondaryProviders: [DelayedLauncherProvider(rows: [smart, smime], delay: .milliseconds(20))],
            secondaryDebounceInterval: .zero
        )
        model.query = "sm"
        model.scheduleSearch()
        await waitForSearch(model)
        #expect(model.results.first == app)
        #expect(model.selectedIndex == 0)
        var opened: URL?
        model.onOpenFile = { opened = $0 }
        model.commit()
        #expect(opened?.lastPathComponent == "Sublime Merge.app")
    }

    /// Usage is per-query (see `recordSuccessfulSelection`/`setResults`), so
    /// a selection recorded for one query must not promote that row when a
    /// different query happens to match it too.
    @Test func usageFromADifferentQueryHasNoCrossQueryEffect() async {
        let oldUsage = Defaults[.launcherSelectionUsage]
        defer { Defaults[.launcherSelectionUsage] = oldUsage }
        Defaults[.launcherSelectionUsage] = [:]
        let app = LauncherResult.app(
            name: "Sublime Merge",
            url: URL(fileURLWithPath: "/Applications/Sublime Merge.app")
        )
        let file = LauncherResult.file(name: "sm.png", url: URL(fileURLWithPath: "/tmp/sm.png"))
        let model = LauncherViewModel(
            instantProviders: [DelayedLauncherProvider(rows: [app, file])],
            secondaryProviders: []
        )
        model.recordSuccessfulSelection(id: app.id, query: "other query")
        model.query = "sm"
        model.scheduleSearch()
        await waitForSearch(model)
        #expect(model.results.first == file)
    }
}
