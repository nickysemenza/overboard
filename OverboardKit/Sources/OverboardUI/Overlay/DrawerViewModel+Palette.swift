import OverboardCore

// MARK: - ⌘K palette

public extension DrawerViewModel {
    var filteredPaletteActions: [ClipAction] {
        let all = self.applicableActions
        let needle = self.paletteQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        // Subsequence "fuzzy" match on the label.
        return all.filter { action in
            var remaining = Substring(needle)
            for char in action.label.lowercased() where char == remaining.first {
                remaining = remaining.dropFirst()
                if remaining.isEmpty {
                    return true
                }
            }
            return remaining.isEmpty
        }
    }

    func togglePalette() {
        guard self.mode == .history else { return }
        if self.isPaletteOpen {
            self.closePalette()
        } else {
            guard !self.selectedItems.isEmpty else { return }
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
        self.runAction(actions[chosen])
    }
}
