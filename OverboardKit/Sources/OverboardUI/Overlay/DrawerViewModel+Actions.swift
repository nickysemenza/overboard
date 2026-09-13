import OverboardCore

// MARK: - Selection movement, commit, pin/delete

public extension DrawerViewModel {
    func moveSelection(_ delta: Int) {
        guard self.entryCount > 0 else { return }
        self.collapseMultiSelection()
        self.selectedIndex = min(max(self.selectedIndex + delta, 0), self.entryCount - 1)
    }

    func select(at index: Int, mode pasteMode: PasteMode = .full) {
        switch self.mode {
        case .history:
            guard self.items.indices.contains(index) else { return }
            self.selectedIndex = index
            self.onCommit(self.items[index], pasteMode)
        case .snippets:
            guard self.snippets.indices.contains(index) else { return }
            self.selectedIndex = index
            self.onCommitSnippet(self.snippets[index])
        }
    }

    func selectCurrent(mode pasteMode: PasteMode = .full) {
        self.select(at: self.selectedIndex, mode: pasteMode)
    }

    func selectTransformed(at index: Int, transform: ClipTransform) {
        guard self.mode == .history, self.items.indices.contains(index) else { return }
        self.selectedIndex = index
        self.onCommitTransform(self.items[index], transform)
    }

    func selectAITransformed(at index: Int, transform: AITransform) {
        guard self.mode == .history, self.items.indices.contains(index) else { return }
        self.selectedIndex = index
        self.onCommitAITransform(self.items[index], transform)
    }

    /// Queue the selected item onto the paste stack and advance selection so
    /// repeated ⌘↩ presses queue a run of items.
    func addSelectedToStack() {
        guard self.mode == .history, self.items.indices.contains(self.selectedIndex) else { return }
        self.stack.push(self.items[self.selectedIndex])
        if self.selectedIndex < self.items.count - 1 {
            self.selectedIndex += 1
        }
    }

    /// Re-derives multi-selection indices from the identities held before a
    /// refresh, dropping ids that no longer exist — the same identity-follow
    /// treatment `selectedIndex` gets via `followItemID`. `internal`: also
    /// called from `refresh(resetSelection:followItemID:)` in the main file.
    internal func remapSelection(to ids: Set<String>) -> Set<Int> {
        guard !ids.isEmpty else { return [] }
        return Set(self.items.enumerated().compactMap { ids.contains($1.id) ? $0 : nil })
    }

    /// Pin/unpin the selected item; selection follows it to its new position.
    func togglePinSelected() {
        guard self.mode == .history, self.items.indices.contains(self.selectedIndex) else { return }
        let item = self.items[self.selectedIndex]
        Task {
            do {
                try await self.store.setPinned(id: item.id, !item.isPinned)
            } catch {
                self.logger.error("pin toggle failed: \(String(describing: error), privacy: .public)")
            }
            await self.refresh(resetSelection: false, followItemID: item.id)
        }
    }

    /// Remove the selected item from history (drawer stays open).
    func deleteSelected() {
        guard self.mode == .history, self.items.indices.contains(self.selectedIndex) else { return }
        let item = self.items[self.selectedIndex]
        let survivingMultiIDs = Set(self.selectedItems.map(\.id)).subtracting([item.id])
        // Optimistically drop the row before the async delete so a rapid repeat
        // (⌘⌫ key-repeat) doesn't re-read the same stale index and delete the
        // same item twice; refresh() reconciles with the store afterwards.
        self.items.remove(at: self.selectedIndex)
        self.selectedIndex = min(self.selectedIndex, max(self.entryCount - 1, 0))
        self.multiSelection = self.remapSelection(to: survivingMultiIDs)
        Task {
            do {
                try await self.store.delete(id: item.id)
            } catch {
                self.logger.error("delete failed: \(String(describing: error), privacy: .public)")
            }
            await self.refresh(resetSelection: false)
        }
    }
}
