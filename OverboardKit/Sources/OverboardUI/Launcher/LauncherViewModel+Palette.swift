import Foundation
import OverboardCore

/// The ⌘K action palette: filtering the selected row's actions by a typed
/// query and navigating/running the filtered list. `isPaletteOpen`,
/// `paletteQuery`, and `paletteIndex` are declared as stored properties on
/// `LauncherViewModel` itself (extensions can't add stored properties).
public extension LauncherViewModel {
    /// Actions for the selected row filtered by a case-insensitive substring of
    /// the label; empty query shows them all.
    var filteredPaletteActions: [LauncherAction] {
        let all = self.selectedActions
        let needle = self.paletteQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { $0.label.lowercased().contains(needle) }
    }

    /// Opens the palette (only when a row with actions is selected) or closes it
    /// if already open.
    func togglePalette() {
        if self.isPaletteOpen {
            self.closePalette()
        } else {
            guard !self.selectedActions.isEmpty else { return }
            self.userSelected = true
            self.paletteQuery = ""
            self.paletteIndex = 0
            self.isPaletteOpen = true
        }
    }

    func closePalette() {
        self.isPaletteOpen = false
    }

    func movePaletteSelection(_ delta: Int) {
        let count = self.filteredPaletteActions.count
        guard count > 0 else { return }
        self.paletteIndex = min(max(self.paletteIndex + delta, 0), count - 1)
    }

    func runPaletteAction(at index: Int? = nil) {
        let actions = self.filteredPaletteActions
        let chosen = index ?? self.paletteIndex
        guard actions.indices.contains(chosen) else { return }
        self.closePalette()
        self.perform(actions[chosen])
    }
}
