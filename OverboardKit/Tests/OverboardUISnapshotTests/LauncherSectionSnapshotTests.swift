import OverboardCore
import OverboardMac
@testable import OverboardUI
import SnapshotTesting
import SwiftUI
import Testing

@MainActor
struct LauncherSectionSnapshotTests {
    /// Mixed rows show consistent section headers (type is conveyed by the
    /// header above each run of rows, not a per-row badge — only the
    /// no-section-header now-playing row keeps one) and a dedicated action
    /// footer. The app path deliberately doesn't exist — a missing bundle
    /// renders the generic app icon instead of a machine-dependent one.
    @Test func sectionHeaders() async throws {
        let store = try Fixtures.store()
        let viewModel = LauncherViewModel(
            instantProviders: [
                StubLauncherProvider(rows: [
                    .app(name: "Demo App", url: URL(fileURLWithPath: "/Applications/OverboardDemo.app")),
                    .clip(Fixtures.item(preview: "demo deploy checklist")),
                    .file(name: "demo notes.md", url: URL(fileURLWithPath: "/tmp/overboard-missing/notes.md")),
                ]),
            ],
            secondaryProviders: []
        )
        viewModel.query = "demo"
        viewModel.scheduleSearch()
        await viewModel.settle()

        let view = LauncherView(viewModel: viewModel, store: store)
        assertSnapshot(
            of: snapshotImage(view, width: 740, height: 370),
            as: snapshotImageStrategy,
            record: snapshotRecordingMode
        )
    }
}
