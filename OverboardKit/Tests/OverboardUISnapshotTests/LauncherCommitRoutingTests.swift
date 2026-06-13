import Foundation
import OverboardCore
@testable import OverboardUI
import Testing

private struct StubProvider: LauncherProvider {
    let rows: [LauncherResult]
    func results(for _: String) async -> [LauncherResult] {
        self.rows
    }
}

/// Pure logic, no snapshots — runs on CI too.
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

        viewModel.prepareForShow()
        #expect(viewModel.query == "zzz")
        while viewModel.results.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        // Rows repopulate from the preserved query (instant router also appends
        // its standing web-search row).
        #expect(viewModel.results.first == .command(.version))
    }

    /// A first-ever open (empty query) still opens to a blank bar.
    @Test func prepareForShowWithEmptyQueryClearsResults() async {
        let viewModel = await makeViewModel(rows: [.command(.version)])

        viewModel.query = ""
        viewModel.prepareForShow()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(viewModel.results.isEmpty)
    }
}
