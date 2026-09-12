import AppKit
import OverboardCore
import OverboardMac
@testable import OverboardUI
import Testing

private struct SizingLauncherProvider: LauncherProvider {
    func results(for query: String) async -> [LauncherResult] {
        let count = query.isEmpty ? 6 : query == "many" ? 20 : query == "one" ? 1 : 0
        return (0 ..< count).map { index in
            .app(name: "\(query) App \(index)", url: URL(fileURLWithPath: "/fixture/app-\(index).app"))
        }
    }
}

@Suite(.serialized)
@MainActor
struct LauncherPanelSizingTests {
    private func waitForSearch(_ model: LauncherViewModel) async throws {
        for _ in 0 ..< 300 where model.isSearching {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(!model.isSearching)
    }

    @Test func openingAndTypingKeepTheSameWindowFrame() async throws {
        let application = NSApplication.shared
        let existingWindows = Set(application.windows.map(\.windowNumber))
        let oldHistory = Defaults[.launcherSearchHistory]
        Defaults[.launcherSearchHistory] = []
        defer { Defaults[.launcherSearchHistory] = oldHistory }
        let model = LauncherViewModel(instantProviders: [SizingLauncherProvider()], secondaryProviders: [])
        model.runningAppPaths = Set((0 ..< 6).map { "/fixture/app-\($0).app" })
        let controller = try LauncherPanelController(store: Fixtures.store(), viewModel: model)
        controller.show()
        let panel = try #require(application.windows.first { $0 is OverlayPanel && !existingWindows.contains($0.windowNumber) })
        defer {
            model.query = ""
            controller.hide()
            panel.close()
        }
        let openingFrame = panel.frame
        try await self.waitForSearch(model)
        #expect(model.results.count == 6)
        #expect(panel.frame == openingFrame, "Suggestions arriving must not resize or reposition the window")

        for (query, count) in [("many", 21), ("one", 2), ("no-match", 1), ("", 6)] {
            controller.setQuery(query)
            #expect(panel.frame == openingFrame, "Typing must not resize the window before results arrive")
            try await self.waitForSearch(model)
            #expect(model.results.count == count)
            #expect(panel.frame == openingFrame, "Result count must not change the window frame")
        }
        controller.hide()
        controller.show()
        #expect(panel.frame == openingFrame, "Reopening must start at the settled size")
        try await self.waitForSearch(model)
        #expect(panel.frame == openingFrame)

        model.togglePalette()
        #expect(model.isPaletteOpen)
        #expect(panel.frame == openingFrame, "The action palette must fit without resizing")
        model.closePalette()
        model.togglePreview()
        let previewFrame = panel.frame
        #expect(previewFrame.width >= openingFrame.width)
        #expect(previewFrame.height >= openingFrame.height)
        #expect(previewFrame.maxY == openingFrame.maxY, "Expanding a preview must keep the search field anchored")
        model.togglePreview()
        #expect(panel.frame == openingFrame)

        model.setScope(.clipboard)
        let clipboardFrame = panel.frame
        #expect(clipboardFrame.maxY == openingFrame.maxY)
        controller.setQuery("no-match")
        try await self.waitForSearch(model)
        #expect(panel.frame == clipboardFrame, "Clipboard filtering must keep the browser size stable")
        for scope in [LauncherScope.files, .apps, .all] {
            model.setScope(scope)
            try await self.waitForSearch(model)
            #expect(panel.frame == openingFrame)
        }
    }
}
