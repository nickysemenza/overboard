import OverboardCore
@testable import OverboardUI
import SnapshotTesting
import SwiftUI
import Testing

@Suite(.localOnly)
@MainActor
struct ActionPaletteSnapshotTests {
    /// Builds a view model with one selected text item so the palette has
    /// applicable actions. The refresh task is private; polling `items` with a
    /// bounded timeout is the pragmatic hook.
    private func makeViewModel() async throws -> DrawerViewModel {
        let store = try Fixtures.store()
        _ = try await store.ingest(Fixtures.textSnapshot("hello world https://example.com"))
        let viewModel = DrawerViewModel(store: store, stack: PasteStack())
        viewModel.prepareForShow()
        for _ in 0 ..< 2000 where viewModel.items.isEmpty {
            await Task.yield()
        }
        try #require(!viewModel.items.isEmpty)
        return viewModel
    }

    // glassPanel's NSVisualEffectView renders flat without a real window;
    // these snapshots verify row content and layout, not the material.

    @Test func allActions() async throws {
        let viewModel = try await self.makeViewModel()
        let view = ActionPalette(viewModel: viewModel)
        assertSnapshot(of: snapshotHost(view, width: 420, height: 480), as: snapshotImageStrategy)
    }

    @Test func fuzzyFiltered() async throws {
        let viewModel = try await self.makeViewModel()
        viewModel.paletteQuery = "case"
        let view = ActionPalette(viewModel: viewModel)
        assertSnapshot(of: snapshotHost(view, width: 420, height: 480), as: snapshotImageStrategy)
    }
}
