import OverboardCore
import SwiftUI

/// ⌘K command palette: fuzzy-filtered actions for the current selection,
/// floating over the card strip. A thin projection of the drawer's
/// `ClipAction`s onto the shared `CommandPaletteView` chrome.
struct ActionPalette: View {
    @Bindable var viewModel: DrawerViewModel
    var maximumHeight: CGFloat = 320

    var body: some View {
        let isPinned = self.viewModel.selectedItem?.isPinned ?? false
        CommandPaletteView(
            items: self.viewModel.filteredPaletteActions.enumerated().map { index, entry in
                CommandPaletteItem(
                    id: entry.id,
                    label: entry.label(isPinned: isPinned),
                    systemImage: entry.systemImage,
                    hint: entry.hint ?? (index == self.viewModel.paletteIndex ? "↩" : nil),
                    detail: entry.detail
                )
            },
            query: self.$viewModel.paletteQuery,
            index: self.$viewModel.paletteIndex,
            emptyMessage: "No matching actions for this selection",
            onRun: { self.viewModel.runPaletteAction(at: $0) },
            maximumHeight: self.maximumHeight
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
