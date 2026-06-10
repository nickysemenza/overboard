import Foundation
import Observation
import OverboardCore

@MainActor
@Observable
public final class DrawerViewModel {
    public private(set) var items: [ClipItem] = []
    public var query: String = ""
    public var selectedIndex: Int = 0

    /// Called when the user commits an item (Return, click, ⌘n).
    public var onCommit: (ClipItem, PasteMode) -> Void = { _, _ in }
    public var onDismiss: () -> Void = {}

    private let store: ClipStore
    private var searchTask: Task<Void, Never>?

    /// Card views need read access for thumbnails and drag payloads.
    var storeForCards: ClipStore {
        self.store
    }

    public init(store: ClipStore) {
        self.store = store
    }

    /// Reset and reload; called every time the drawer is summoned.
    public func prepareForShow() {
        self.query = ""
        self.selectedIndex = 0
        self.searchTask?.cancel()
        self.searchTask = Task { await self.refresh() }
    }

    public func scheduleSearch() {
        self.searchTask?.cancel()
        self.searchTask = Task {
            // Debounce so we don't hit FTS on every keystroke.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self.refresh(resetSelection: true)
        }
    }

    private func refresh(resetSelection: Bool = true, followItemID: String? = nil) async {
        do {
            let query = self.query
            let results = query.trimmingCharacters(in: .whitespaces).isEmpty
                ? try await self.store.recent(limit: 100)
                : try await self.store.search(query, limit: 100)
            guard !Task.isCancelled else { return }
            self.items = results
            if let followItemID, let index = results.firstIndex(where: { $0.id == followItemID }) {
                self.selectedIndex = index
            } else if resetSelection {
                self.selectedIndex = 0
            } else {
                self.selectedIndex = min(self.selectedIndex, max(self.items.count - 1, 0))
            }
        } catch {
            self.items = []
        }
    }

    public func moveSelection(_ delta: Int) {
        guard !self.items.isEmpty else { return }
        self.selectedIndex = min(max(self.selectedIndex + delta, 0), self.items.count - 1)
    }

    public func select(at index: Int, mode: PasteMode = .full) {
        guard self.items.indices.contains(index) else { return }
        self.selectedIndex = index
        self.onCommit(self.items[index], mode)
    }

    public func selectCurrent(mode: PasteMode = .full) {
        guard self.items.indices.contains(self.selectedIndex) else { return }
        self.onCommit(self.items[self.selectedIndex], mode)
    }

    /// Pin/unpin the selected item; selection follows it to its new position.
    public func togglePinSelected() {
        guard self.items.indices.contains(self.selectedIndex) else { return }
        let item = self.items[self.selectedIndex]
        Task {
            try? await self.store.setPinned(id: item.id, !item.isPinned)
            await self.refresh(resetSelection: false, followItemID: item.id)
        }
    }

    /// Remove the selected item from history (drawer stays open).
    public func deleteSelected() {
        guard self.items.indices.contains(self.selectedIndex) else { return }
        let item = self.items[self.selectedIndex]
        Task {
            try? await self.store.delete(id: item.id)
            await self.refresh(resetSelection: false)
        }
    }
}
