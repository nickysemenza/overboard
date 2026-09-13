import OverboardCore

// MARK: - Multi-selection

public extension DrawerViewModel {
    /// All selected items, anchor included, in display order.
    var selectedItems: [ClipItem] {
        guard self.mode == .history else { return [] }
        let indices = self.multiSelection.union([self.selectedIndex])
            .filter { self.items.indices.contains($0) }
            .sorted()
        return indices.map { self.items[$0] }
    }

    func isIndexSelected(_ index: Int) -> Bool {
        index == self.selectedIndex || self.multiSelection.contains(index)
    }

    /// ⇧←/⇧→: grow the selection from the anchor.
    func extendSelection(_ delta: Int) {
        guard self.mode == .history, !self.items.isEmpty else { return }
        let next = min(max(self.selectedIndex + delta, 0), self.items.count - 1)
        guard next != self.selectedIndex else { return }
        self.multiSelection.insert(self.selectedIndex)
        self.multiSelection.insert(next)
        self.selectedIndex = next
    }

    /// ⌘-click: toggle one card's membership.
    func toggleSelection(at index: Int) {
        guard self.mode == .history, self.items.indices.contains(index) else { return }
        if index == self.selectedIndex {
            // Re-anchor on some other selected card, if any.
            if let replacement = self.multiSelection.sorted().first {
                self.selectedIndex = replacement
                self.multiSelection.remove(replacement)
            }
        } else if self.multiSelection.contains(index) {
            self.multiSelection.remove(index)
        } else {
            self.multiSelection.insert(index)
        }
    }

    func collapseMultiSelection() {
        self.multiSelection.removeAll()
    }

    /// Navigate to a specific item (e.g. from the Related strip). If it is
    /// already in the current list, just select it; otherwise clear the query
    /// and refetch so it appears. Preview state is left untouched — the pane
    /// reloads itself via `task(id:)`.
    func jump(toItemID id: String) {
        if let index = self.items.firstIndex(where: { $0.id == id }) {
            self.collapseMultiSelection()
            self.selectedIndex = index
            return
        }
        self.query = ""
        self.searchTask?.cancel()
        self.searchTask = Task { await self.refresh(resetSelection: false, followItemID: id) }
    }

    /// Actions applicable to the current selection.
    var applicableActions: [ClipAction] {
        ClipAction.applicable(to: self.selectedItems)
    }

    func runAction(_ action: ClipAction) {
        let items = self.selectedItems
        guard !items.isEmpty else { return }
        self.onRunAction(action, items)
    }
}
