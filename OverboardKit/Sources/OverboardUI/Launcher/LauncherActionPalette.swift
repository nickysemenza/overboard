import OverboardCore
import SwiftUI

/// ⌘K command palette for the launcher: the actions applicable to the selected
/// row, projected onto the shared `CommandPaletteView` chrome.
struct LauncherActionPalette: View {
    @Bindable var viewModel: LauncherViewModel

    var body: some View {
        CommandPaletteView(
            items: self.viewModel.filteredPaletteActions.enumerated().map { index, action in
                CommandPaletteItem(id: action.id, label: action.label, systemImage: action.systemImage, hint: LauncherActions.hint(at: index))
            },
            query: self.$viewModel.paletteQuery,
            index: self.$viewModel.paletteIndex,
            emptyMessage: "No actions for this result",
            onRun: { self.viewModel.runPaletteAction(at: $0) }
        )
    }
}

#if DEBUG
    #Preview("Actions") {
        LauncherActionPaletteDemo()
            .frame(width: 420, height: 320)
    }

    /// Waits for the launcher's instant search pass to land (results come back
    /// asynchronously through `scheduleSearch`), selects a link clip, then opens
    /// the ⌘K palette — mirrors `LauncherActionPaletteSnapshotTests.makeViewModel`.
    private struct LauncherActionPaletteDemo: View {
        @State private var viewModel: LauncherViewModel?

        var body: some View {
            Group {
                if let viewModel {
                    LauncherActionPalette(viewModel: viewModel)
                } else {
                    ProgressView()
                }
            }
            .task {
                let model = LauncherViewModel(
                    instantProviders: [StubLauncherProvider(rows: [
                        .clip(Fixtures.item(kind: .link, preview: "https://example.com")),
                    ])],
                    secondaryProviders: []
                )
                model.query = "zzz"
                model.scheduleSearch()
                for _ in 0 ..< 2000 where model.results.isEmpty {
                    await Task.yield()
                }
                model.togglePalette()
                self.viewModel = model
            }
        }
    }
#endif
