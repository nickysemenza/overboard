import OverboardCore
import SwiftUI

/// ⌘K command palette: fuzzy-filtered actions for the current selection,
/// floating over the card strip. A thin projection of the drawer's
/// `ClipAction`s onto the shared `CommandPaletteView` chrome.
struct ActionPalette: View {
    @Bindable var viewModel: DrawerViewModel
    var glassNamespace: Namespace.ID?

    var body: some View {
        CommandPaletteView(
            items: self.viewModel.filteredPaletteActions.map {
                CommandPaletteItem(id: $0.id, label: $0.label, systemImage: $0.systemImage)
            },
            query: self.$viewModel.paletteQuery,
            index: self.$viewModel.paletteIndex,
            emptyMessage: "No matching actions for this selection",
            onRun: { self.viewModel.runPaletteAction(at: $0) },
            glassNamespace: self.glassNamespace
        )
    }
}
