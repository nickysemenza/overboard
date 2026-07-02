import OverboardCore
import SwiftUI

/// ⌘K command palette for the launcher: the actions applicable to the selected
/// row, projected onto the shared `CommandPaletteView` chrome.
struct LauncherActionPalette: View {
    @Bindable var viewModel: LauncherViewModel

    var body: some View {
        CommandPaletteView(
            items: self.viewModel.filteredPaletteActions.map {
                CommandPaletteItem(id: $0.id, label: $0.label, systemImage: $0.systemImage)
            },
            query: self.$viewModel.paletteQuery,
            index: self.$viewModel.paletteIndex,
            emptyMessage: "No actions for this result",
            onRun: { self.viewModel.runPaletteAction(at: $0) }
        )
    }
}
