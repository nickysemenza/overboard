import OverboardCore
@testable import OverboardUI
import SnapshotTesting
import SwiftUI
import Testing

private struct StubProvider: LauncherProvider {
    let rows: [LauncherResult]
    func results(for _: String) async -> [LauncherResult] {
        self.rows
    }
}

@Suite(.localOnly)
@MainActor
struct LauncherActionPaletteSnapshotTests {
    /// A link clip selected so the palette lists paste / copy / paste plain /
    /// open link — the richest launcher action set.
    private func makeViewModel() async -> LauncherViewModel {
        let viewModel = LauncherViewModel(
            instantProviders: [StubProvider(rows: [
                .clip(Fixtures.item(kind: .link, preview: "https://example.com")),
            ])],
            secondaryProviders: []
        )
        viewModel.query = "zzz"
        viewModel.scheduleSearch()
        while viewModel.results.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        viewModel.togglePalette()
        return viewModel
    }

    @Test func light() async {
        let viewModel = await self.makeViewModel()
        let view = LauncherActionPalette(viewModel: viewModel)
        assertSnapshot(of: snapshotHost(view, width: 420, height: 320), as: snapshotImageStrategy)
    }

    @Test func dark() async {
        let viewModel = await self.makeViewModel()
        let view = LauncherActionPalette(viewModel: viewModel)
        assertSnapshot(
            of: snapshotHost(view, width: 420, height: 320, dark: true),
            as: snapshotImageStrategy
        )
    }
}
