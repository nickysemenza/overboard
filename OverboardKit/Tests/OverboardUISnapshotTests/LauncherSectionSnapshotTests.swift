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
struct LauncherSectionSnapshotTests {
    /// App + clip + file rows through the real view model, so headers render
    /// exactly as the annotate pass produces them (plus the standing web row).
    /// The app path deliberately doesn't exist — a missing bundle renders the
    /// generic app icon instead of a machine-dependent one.
    @Test func sectionHeaders() async throws {
        let store = try Fixtures.store()
        let viewModel = LauncherViewModel(
            instantProviders: [StubProvider(rows: [
                .app(name: "Demo App", url: URL(fileURLWithPath: "/Applications/OverboardDemo.app")),
                .clip(Fixtures.item(preview: "deploy checklist")),
                .file(name: "notes.md", url: URL(fileURLWithPath: "/tmp/overboard-missing/notes.md")),
            ])],
            secondaryProviders: []
        )
        viewModel.query = "zzz"
        viewModel.scheduleSearch()
        while viewModel.results.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let view = LauncherView(viewModel: viewModel, store: store)
        // 82 bar + 17 divider + 4 rows × 45 + 3 headers × 18 = 333.
        assertSnapshot(of: snapshotHost(view, width: 640, height: 333), as: snapshotImageStrategy)
    }
}
