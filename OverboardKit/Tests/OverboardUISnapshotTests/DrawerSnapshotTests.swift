import AppKit
import OverboardCore
@testable import OverboardUI
import SnapshotTesting
import SwiftUI
import Testing

/// Pins the collapsed drawer's whole panel in one image: the shared
/// `PanelFooterBar` (step 1), the card footers, and `CardMetrics
/// .collapsedPanelHeight` itself, so a future geometry change to any of
/// them shows up here instead of only in an isolated component suite.
@MainActor
struct DrawerSnapshotTests {
    /// Three text clips (deterministic `Fixtures.date`, so `lastUsedAt` never
    /// drifts) and a fixed target app name for the footer's "Paste to …" label.
    private func makeViewModel() async throws -> DrawerViewModel {
        let store = try Fixtures.store()
        _ = try await store.ingest(Fixtures.textSnapshot(
            "Pick up the package before 6pm — front desk closes early on Fridays."
        ))
        _ = try await store.ingest(Fixtures.textSnapshot("https://example.com/docs"))
        _ = try await store.ingest(Fixtures.textSnapshot("func total(for items: [Item]) -> Int { items.count }"))
        let viewModel = DrawerViewModel(store: store, stack: PasteStack())
        viewModel.targetAppName = "Demo Editor"
        viewModel.prepareForShow()
        for _ in 0 ..< 2000 where viewModel.items.isEmpty {
            await Task.yield()
        }
        try #require(!viewModel.items.isEmpty)
        return viewModel
    }

    /// Cards ripple in via `cardEntrance`, an explicit `withAnimation` fired
    /// from `onAppear`; `snapshotHost` sets `skipsEntranceMotion` so they land
    /// settled on the first layout pass, the way every other suite captures.
    private func drawerImage(_ viewModel: DrawerViewModel, dark: Bool = false) -> NSImage {
        snapshotImage(
            DrawerView(viewModel: viewModel), width: 900, height: CardMetrics.collapsedPanelHeight, dark: dark
        )
    }

    @Test func light() async throws {
        let viewModel = try await self.makeViewModel()
        assertSnapshot(of: self.drawerImage(viewModel), as: snapshotImageStrategy, record: snapshotRecordingMode)
    }

    @Test func dark() async throws {
        let viewModel = try await self.makeViewModel()
        assertSnapshot(
            of: self.drawerImage(viewModel, dark: true),
            as: snapshotImageStrategy,
            record: snapshotRecordingMode
        )
    }
}
