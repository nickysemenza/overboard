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

@Suite(.serialized)
@MainActor
struct LauncherScopeTests {
    private func waitForSearch(_ model: LauncherViewModel) async {
        for _ in 0 ..< 300 where model.isSearching {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(!model.isSearching)
    }

    @Test func firstSelectionTracksBestResultUntilUserNavigates() async {
        let file = LauncherResult.file(name: "hello.txt", url: URL(fileURLWithPath: "/tmp/hello.txt"))
        let model = LauncherViewModel(secondaryProviders: [DelayedLauncherProvider(rows: [file], delay: .milliseconds(40))])
        model.query = "hello"
        model.scheduleSearch()
        await self.waitForSearch(model)
        #expect(model.selectedResult == file)
        var opened: URL?
        model.onOpenFile = { opened = $0 }
        model.commit()
        #expect(opened?.lastPathComponent == "hello.txt")
    }

    @Test func lateResultsCannotReplaceManualSelection() async {
        let app = LauncherResult.app(name: "Hello Helper", url: URL(fileURLWithPath: "/Applications/Hello Helper.app"))
        let file = LauncherResult.file(name: "hello.txt", url: URL(fileURLWithPath: "/tmp/hello.txt"))
        let model = LauncherViewModel(instantProviders: [DelayedLauncherProvider(rows: [app])], secondaryProviders: [DelayedLauncherProvider(rows: [file], delay: .milliseconds(80))])
        model.query = "hello"
        model.scheduleSearch()
        for _ in 0 ..< 100 where model.results.count < 2 {
            try? await Task.sleep(for: .milliseconds(1))
        }
        model.moveSelection(1)
        let chosen = model.selectedResult
        await self.waitForSearch(model)
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
        let model = LauncherViewModel(instantProviders: [DelayedLauncherProvider(rows: [app, file])], secondaryProviders: [])
        model.query = "notes"
        model.setScope(.apps)
        await self.waitForSearch(model)
        #expect(model.results == [app])
        model.setScope(.files)
        await self.waitForSearch(model)
        #expect(model.results == [file])
        model.setScope(.all)
        await self.waitForSearch(model)
        #expect(model.results.contains(app) && model.results.contains(file))
        #expect(model.results.contains { if case .webSearch = $0 { true } else { false } })
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
        let model = LauncherViewModel(instantProviders: [DelayedLauncherProvider(rows: [running, frequent])], secondaryProviders: [])
        model.runningAppPaths = ["/fixture/running.app"]
        model.scheduleSearch()
        await self.waitForSearch(model)
        #expect(model.results.first == running)
        #expect(Defaults[.launcherItemUseCounts].isEmpty)
        model.recordSuccessfulSelection(id: frequent.id, query: "")
        model.scheduleSearch()
        await self.waitForSearch(model)
        #expect(model.results.first == frequent)
        #expect(Defaults[.launcherItemUseCounts][frequent.id] == 1)
        model.setScope(.apps)
        await self.waitForSearch(model)
        #expect(model.results.first == frequent)
    }

    /// `scheduleSearch` deliberately stops clearing `results` synchronously on
    /// every keystroke (that used to flash the "No results" empty state
    /// between characters for a fast typist) — the previous list now stays on
    /// screen until the instant pass's `setResults` call replaces it.
    @Test func newQueryKeepsPreviousResultsVisibleUntilTheInstantPassReplacesThem() async {
        let file = LauncherResult.file(name: "hello.txt", url: URL(fileURLWithPath: "/tmp/hello.txt"))
        let model = LauncherViewModel(secondaryProviders: [DelayedLauncherProvider(rows: [file], delay: .milliseconds(30))])
        model.query = "hello"
        model.scheduleSearch()
        await self.waitForSearch(model)
        #expect(!model.results.isEmpty)
        model.query = "completely different"
        model.scheduleSearch()
        // No await yet: the instant pass hasn't had a chance to run, so this
        // is the synchronous state right after the keystroke.
        #expect(!model.results.isEmpty)
        await self.waitForSearch(model)
        model.stopObserving()
    }

    @Test func clipboardPaginationKeepsSelectionAndFiltersResetThePage() async throws {
        let store = try Fixtures.store()
        for index in 0 ..< 205 {
            _ = try await store.ingest(PasteboardSnapshot(reps: [.init(uti: WellKnownUTI.plainText, data: Data("history entry \(index)".utf8))], sourceBundleID: nil, sourceAppName: nil))
        }
        let model = LauncherViewModel(secondaryProviders: [], clipboardStore: store)
        model.setScope(.clipboard)
        await self.waitForSearch(model)
        #expect(model.results.count == 200 && model.hasMoreClipboard)
        model.select(at: 20)
        let selected = model.selectedResult?.id
        model.loadMoreClipboard()
        await self.waitForSearch(model)
        #expect(model.results.count == 205 && !model.hasMoreClipboard)
        #expect(model.selectedResult?.id == selected)
        model.clipboardFilter.kind = .image
        model.scheduleSearch()
        await self.waitForSearch(model)
        #expect(model.results.isEmpty && !model.hasMoreClipboard)
    }

    @Test func cloudResultOnlyDownloadsOnCommit() async {
        let cloud = LauncherResult.file(name: "budget.xlsx", url: URL(fileURLWithPath: "/fixture/budget.xlsx"), info: FileSearchInfo(availability: .cloud))
        let model = LauncherViewModel(instantProviders: [DelayedLauncherProvider(rows: [cloud])], secondaryProviders: [])
        var opened = 0
        model.onOpenFile = { _ in opened += 1 }
        model.query = "budget"
        model.setScope(.files)
        await self.waitForSearch(model)
        model.select(at: 0)
        #expect(opened == 0)
        #expect(model.primaryActionLabel == "Download & Open")
        model.commit()
        #expect(opened == 1)
    }

    /// Regression test for two related bugs in `scheduleSearch`: (1) it used
    /// to blank `results` synchronously on every keystroke, flashing the
    /// "No results" empty state for a fast typist, and (2) a search task
    /// cancelled by a newer keystroke could still clear `isSearching` after
    /// the newer task had already claimed (or finished) it, leaving the
    /// spinner stuck forever spinning or falsely idle. A slow instant
    /// provider stands in for real provider latency so each search stays
    /// in flight long enough to observe both fixes.
    @Test func rapidQueryChangesNeverFlashEmptyResultsAndClearTheSpinner() async {
        let terminal = LauncherResult.app(name: "Terminal", url: URL(fileURLWithPath: "/Applications/Terminal.app"))
        let model = LauncherViewModel(
            instantProviders: [DelayedLauncherProvider(rows: [terminal], delay: .milliseconds(20))],
            secondaryProviders: []
        )
        model.query = "t"
        model.scheduleSearch()
        await self.waitForSearch(model)
        #expect(!model.results.isEmpty)

        // A bounded poll is the simplest reliable way to sample `results`
        // between the rapid-fire keystrokes below; the view model exposes no
        // dedicated "did the list ever go empty" signal.
        var observedEmptyResults = false
        let observer = Task {
            while !Task.isCancelled {
                if model.results.isEmpty { observedEmptyResults = true }
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

        await self.waitForSearch(model)
        observer.cancel()

        #expect(!observedEmptyResults)
        #expect(!model.isSearching)
        #expect(!model.results.isEmpty)
    }
}
