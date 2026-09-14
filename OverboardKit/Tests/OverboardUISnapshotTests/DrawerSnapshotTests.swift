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

    /// Cards ripple in via `cardEntrance`'s spring, an explicit `withAnimation`
    /// fired from `onAppear` — unlike `ItemCardSnapshotTests`, which renders
    /// `ItemCardView` directly and never passes through that modifier.
    /// `accessibilityReduceMotion` is get-only (no `.environment` override),
    /// and an explicit `withAnimation` also ignores an ambient `.transaction
    /// { $0.disablesAnimations = true }`, so neither the usual snapshot-test
    /// escape hatch applies here. What the animation *does* need is a real
    /// window: `snapshotHost`'s bare, never-added-to-a-window `NSHostingView`
    /// never receives a display-link tick, so the spring stays parked at its
    /// start value (opacity 0) no matter how long the run loop is pumped
    /// afterwards. Hosting it in an actual (off-screen, borderless) window
    /// lets the animation drive forward in real time; waiting out its worst
    /// case (0.36s spring + this strip's up to 3-card, 0.028s-each stagger)
    /// before capturing then reliably lands on the settled, fully-shown state.
    private func drawerImage(_ viewModel: DrawerViewModel, dark: Bool = false) -> NSImage {
        let host = snapshotHost(
            DrawerView(viewModel: viewModel), width: 900, height: CardMetrics.collapsedPanelHeight, dark: dark
        )
        let window = NSWindow(
            contentRect: NSRect(x: 20000, y: 20000, width: 900, height: CardMetrics.collapsedPanelHeight),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        let image = capture(host)
        window.orderOut(nil)
        return image
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
