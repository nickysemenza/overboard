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

/// What `openingAndTypingKeepTheSameWindowFrame` needs after opening the
/// panel and waiting for the initial suggestions — factored out purely to
/// keep that test's own body under SwiftLint's function_body_length.
private struct PanelSizingFixture {
    let model: LauncherViewModel
    let controller: LauncherPanelController
    let panel: NSWindow
    let openingFrame: NSRect
}

@Suite(.serialized)
@MainActor
struct LauncherPanelSizingTests {
    private func waitForSearch(_ model: LauncherViewModel) async throws {
        await model.settle()
        try #require(!model.isSearching)
    }

    /// Opens a panel with six suggested apps, waits for them to land, and
    /// confirms that arrival alone didn't move or resize the window — the
    /// baseline every assertion in the test builds on.
    private func makeSizingFixture() async throws -> PanelSizingFixture {
        let application = NSApplication.shared
        let existingWindows = Set(application.windows.map(\.windowNumber))
        let model = LauncherViewModel(instantProviders: [SizingLauncherProvider()], secondaryProviders: [])
        model.runningAppPaths = Set((0 ..< 6).map { "/fixture/app-\($0).app" })
        let controller = try LauncherPanelController(store: Fixtures.store(), viewModel: model)
        controller.show()
        let panel = try #require(application.windows
            .first { $0 is OverlayPanel && !existingWindows.contains($0.windowNumber) })
        let openingFrame = panel.frame
        try await self.waitForSearch(model)
        #expect(model.results.count == 6)
        #expect(panel.frame == openingFrame, "Suggestions arriving must not resize or reposition the window")
        return PanelSizingFixture(model: model, controller: controller, panel: panel, openingFrame: openingFrame)
    }

    @Test func openingAndTypingKeepTheSameWindowFrame() async throws {
        let oldHistory = Defaults[.launcherSearchHistory]
        Defaults[.launcherSearchHistory] = []
        defer { Defaults[.launcherSearchHistory] = oldHistory }
        let fixture = try await self.makeSizingFixture()
        let model = fixture.model
        let controller = fixture.controller
        let panel = fixture.panel
        let openingFrame = fixture.openingFrame
        defer {
            model.query = ""
            controller.hide()
            panel.close()
        }

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
