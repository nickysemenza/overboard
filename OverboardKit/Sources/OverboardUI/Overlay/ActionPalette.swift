import OverboardCore
import SwiftUI

/// ⌘K command palette: fuzzy-filtered actions for the current selection,
/// floating over the card strip. A thin projection of the drawer's
/// `ClipAction`s onto the shared `CommandPaletteView` chrome.
struct ActionPalette: View {
    @Bindable var viewModel: DrawerViewModel

    var body: some View {
        let isPinned = self.viewModel.selectedItem?.isPinned ?? false
        CommandPaletteView(
            items: self.viewModel.filteredPaletteActions.map { entry in
                CommandPaletteItem(
                    id: entry.id,
                    label: entry.label(isPinned: isPinned),
                    systemImage: entry.systemImage,
                    hint: entry.hint
                )
            },
            query: self.$viewModel.paletteQuery,
            index: self.$viewModel.paletteIndex,
            emptyMessage: "No matching actions for this selection",
            onRun: { self.viewModel.runPaletteAction(at: $0) }
        )
    }
}

#if DEBUG
    #Preview("Actions") {
        SeededPreview { store in
            let viewModel = Fixtures.drawerViewModel(store: store)
            return ActionPalette(viewModel: viewModel)
        }
        .frame(width: 420, height: 480)
    }
#endif
