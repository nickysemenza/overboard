import Foundation
import Observation
import OverboardCore

public enum DrawerMode: Sendable {
    case history
    case snippets
}

@MainActor
@Observable
public final class DrawerViewModel {
    public private(set) var items: [ClipItem] = []
    public private(set) var snippets: [Snippet] = []
    public private(set) var mode: DrawerMode = .history
    public var query: String = ""
    public var selectedIndex: Int = 0

    public let stack: PasteStack

    /// Called when the user commits an item (Return, click, ⌘n).
    public var onCommit: (ClipItem, PasteMode) -> Void = { _, _ in }
    public var onCommitSnippet: (Snippet) -> Void = { _ in }
    public var onCommitTransform: (ClipItem, ClipTransform) -> Void = { _, _ in }
    public var onDismiss: () -> Void = {}

    private let store: ClipStore
    private var searchTask: Task<Void, Never>?

    /// Card views need read access for thumbnails and drag payloads.
    var storeForCards: ClipStore {
        self.store
    }

    public init(store: ClipStore, stack: PasteStack) {
        self.store = store
        self.stack = stack
    }

    public var entryCount: Int {
        self.mode == .history ? self.items.count : self.snippets.count
    }

    /// Reset and reload; called every time the drawer is summoned.
    public func prepareForShow() {
        self.query = ""
        self.selectedIndex = 0
        self.mode = .history
        self.searchTask?.cancel()
        self.searchTask = Task { await self.refresh() }
    }

    public func toggleMode() {
        self.mode = self.mode == .history ? .snippets : .history
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
            switch self.mode {
            case .history:
                let trimmed = query.trimmingCharacters(in: .whitespaces)
                var results: [ClipItem]
                if trimmed.isEmpty {
                    results = try await self.store.recent(limit: 100)
                } else {
                    results = try await self.store.search(query, limit: 100)
                    // Semantic extras: meaning-based matches FTS missed.
                    if trimmed.count >= 4 {
                        let extras = await (try? self.store.semanticSearch(trimmed, limit: 8)) ?? []
                        let seen = Set(results.map(\.id))
                        results += extras.filter { !seen.contains($0.id) }
                    }
                }
                guard !Task.isCancelled else { return }
                self.items = results
            case .snippets:
                let results = try await self.store.searchSnippets(query)
                guard !Task.isCancelled else { return }
                self.snippets = results
            }
            if let followItemID, let index = self.items.firstIndex(where: { $0.id == followItemID }) {
                self.selectedIndex = index
            } else if resetSelection {
                self.selectedIndex = 0
            } else {
                self.selectedIndex = min(self.selectedIndex, max(self.entryCount - 1, 0))
            }
        } catch {
            self.items = []
            self.snippets = []
        }
    }

    public func moveSelection(_ delta: Int) {
        guard self.entryCount > 0 else { return }
        self.selectedIndex = min(max(self.selectedIndex + delta, 0), self.entryCount - 1)
    }

    public func select(at index: Int, mode pasteMode: PasteMode = .full) {
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

    public func selectCurrent(mode pasteMode: PasteMode = .full) {
        self.select(at: self.selectedIndex, mode: pasteMode)
    }

    public func selectTransformed(at index: Int, transform: ClipTransform) {
        guard self.mode == .history, self.items.indices.contains(index) else { return }
        self.selectedIndex = index
        self.onCommitTransform(self.items[index], transform)
    }

    /// Queue the selected item onto the paste stack and advance selection so
    /// repeated ⌘↩ presses queue a run of items.
    public func addSelectedToStack() {
        guard self.mode == .history, self.items.indices.contains(self.selectedIndex) else { return }
        self.stack.push(self.items[self.selectedIndex])
        if self.selectedIndex < self.items.count - 1 {
            self.selectedIndex += 1
        }
    }

    /// Pin/unpin the selected item; selection follows it to its new position.
    public func togglePinSelected() {
        guard self.mode == .history, self.items.indices.contains(self.selectedIndex) else { return }
        let item = self.items[self.selectedIndex]
        Task {
            try? await self.store.setPinned(id: item.id, !item.isPinned)
            await self.refresh(resetSelection: false, followItemID: item.id)
        }
    }

    /// Remove the selected item from history (drawer stays open).
    public func deleteSelected() {
        guard self.mode == .history, self.items.indices.contains(self.selectedIndex) else { return }
        let item = self.items[self.selectedIndex]
        Task {
            try? await self.store.delete(id: item.id)
            await self.refresh(resetSelection: false)
        }
    }
}
