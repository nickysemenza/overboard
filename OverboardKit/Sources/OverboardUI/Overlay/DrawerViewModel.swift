import AsyncAlgorithms
import Foundation
import Observation
import OverboardCore

public enum DrawerMode: Sendable {
    case history
    case snippets
}

public enum PreviewState: Sendable {
    case hidden
    case viewing
    case editing
}

@MainActor
@Observable
public final class DrawerViewModel {
    public private(set) var items: [ClipItem] = []
    public private(set) var snippets: [Snippet] = []
    public private(set) var mode: DrawerMode = .history
    public var query: String = ""
    public var selectedIndex: Int = 0
    /// Extra selected indices beyond the anchor (⇧arrows / ⌘-click).
    /// Empty means plain single selection.
    public private(set) var multiSelection: Set<Int> = []

    public let stack: PasteStack

    /// Called when the user commits an item (Return, click, ⌘n).
    public var onCommit: (ClipItem, PasteMode) -> Void = { _, _ in }
    public var onCommitSnippet: (Snippet) -> Void = { _ in }
    public var onCommitTransform: (ClipItem, ClipTransform) -> Void = { _, _ in }
    public var onCommitAITransform: (ClipItem, AITransform) -> Void = { _, _ in }
    public var onDismiss: () -> Void = {}
    /// Set by DrawerView, which owns the SwiftUI openSettings environment action.
    public var onOpenSettings: () -> Void = {}
    /// Runs a clip action against the selected items.
    public var onRunAction: (ClipAction, [ClipItem]) -> Void = { _, _ in }

    // MARK: Multi-selection

    /// All selected items, anchor included, in display order.
    public var selectedItems: [ClipItem] {
        guard self.mode == .history else { return [] }
        let indices = self.multiSelection.union([self.selectedIndex])
            .filter { self.items.indices.contains($0) }
            .sorted()
        return indices.map { self.items[$0] }
    }

    public func isIndexSelected(_ index: Int) -> Bool {
        index == self.selectedIndex || self.multiSelection.contains(index)
    }

    /// ⇧←/⇧→: grow the selection from the anchor.
    public func extendSelection(_ delta: Int) {
        guard self.mode == .history, !self.items.isEmpty else { return }
        let next = min(max(self.selectedIndex + delta, 0), self.items.count - 1)
        guard next != self.selectedIndex else { return }
        self.multiSelection.insert(self.selectedIndex)
        self.multiSelection.insert(next)
        self.selectedIndex = next
    }

    /// ⌘-click: toggle one card's membership.
    public func toggleSelection(at index: Int) {
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

    public func collapseMultiSelection() {
        self.multiSelection.removeAll()
    }

    /// Actions applicable to the current selection.
    public var applicableActions: [ClipAction] {
        ClipAction.applicable(to: self.selectedItems)
    }

    public func runAction(_ action: ClipAction) {
        let items = self.selectedItems
        guard !items.isEmpty else { return }
        self.onRunAction(action, items)
    }

    // MARK: ⌘K palette

    public private(set) var isPaletteOpen = false
    public var paletteQuery: String = ""
    public var paletteIndex: Int = 0

    public var filteredPaletteActions: [ClipAction] {
        let all = self.applicableActions
        let needle = self.paletteQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        // Subsequence "fuzzy" match on the label.
        return all.filter { action in
            var remaining = Substring(needle)
            for char in action.label.lowercased() where char == remaining.first {
                remaining = remaining.dropFirst()
                if remaining.isEmpty { return true }
            }
            return remaining.isEmpty
        }
    }

    public func togglePalette() {
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

    public func closePalette() {
        self.isPaletteOpen = false
    }

    public func movePaletteSelection(_ delta: Int) {
        let count = self.filteredPaletteActions.count
        guard count > 0 else { return }
        self.paletteIndex = min(max(self.paletteIndex + delta, 0), count - 1)
    }

    public func runPaletteAction(at index: Int? = nil) {
        let actions = self.filteredPaletteActions
        let chosen = index ?? self.paletteIndex
        guard actions.indices.contains(chosen) else { return }
        self.closePalette()
        self.runAction(actions[chosen])
    }

    // MARK: Preview / edit

    public private(set) var previewState: PreviewState = .hidden
    public var editText: String = ""
    /// Pastes user-edited text instead of the original item.
    public var onCommitEditedText: (String) -> Void = { _ in }
    /// The controller resizes the panel when the preview pane opens/closes.
    public var onPreviewVisibilityChanged: (Bool) -> Void = { _ in }

    public var selectedItem: ClipItem? {
        self.mode == .history && self.items.indices.contains(self.selectedIndex)
            ? self.items[self.selectedIndex] : nil
    }

    public func togglePreview() {
        switch self.previewState {
        case .hidden:
            guard self.selectedItem != nil else { return }
            self.previewState = .viewing
            self.onPreviewVisibilityChanged(true)
        case .viewing, .editing:
            self.closePreview()
        }
    }

    public func closePreview() {
        guard self.previewState != .hidden else { return }
        self.previewState = .hidden
        self.onPreviewVisibilityChanged(false)
    }

    public func beginEdit() {
        guard let item = self.selectedItem,
              item.kind == .text || item.kind == .link
        else { return }
        let wasHidden = self.previewState == .hidden
        Task {
            self.editText = await (try? self.store.plainText(for: item.id))
                ?? item.previewText ?? ""
            self.previewState = .editing
            if wasHidden {
                self.onPreviewVisibilityChanged(true)
            }
        }
    }

    public func commitEdit() {
        guard self.previewState == .editing else { return }
        let text = self.editText
        self.closePreview()
        self.onCommitEditedText(text)
    }

    private let store: ClipStore
    private var searchTask: Task<Void, Never>?
    private var liveUpdateTask: Task<Void, Never>?
    /// Keystrokes funnel through here; one long-lived consumer debounces them.
    private let searchChannel = AsyncChannel<Void>()
    private var searchDebounceTask: Task<Void, Never>?

    /// Card views need read access for thumbnails and drag payloads.
    var storeForCards: ClipStore {
        self.store
    }

    public init(store: ClipStore, stack: PasteStack) {
        self.store = store
        self.stack = stack
        // Debounce so we don't hit FTS on every keystroke. A pending refresh
        // surviving prepareForShow/toggleMode is harmless: it re-runs the
        // current (reset) query.
        self.searchDebounceTask = Task { [weak self, searchChannel] in
            for await _ in searchChannel.debounce(for: .milliseconds(120)) {
                await self?.refresh(resetSelection: true)
            }
        }
    }

    public var entryCount: Int {
        self.mode == .history ? self.items.count : self.snippets.count
    }

    /// Bumped on every summon so the card strip re-runs entrance animations.
    public private(set) var showGeneration = 0

    /// Reset and reload; called every time the drawer is summoned.
    public func prepareForShow() {
        self.query = ""
        self.selectedIndex = 0
        self.multiSelection = []
        self.mode = .history
        // Hiding the drawer with the palette open must not resurface a stale
        // palette on the next summon.
        self.isPaletteOpen = false
        self.showGeneration += 1
        // No visibility callback: show() always sets the collapsed frame.
        self.previewState = .hidden
        self.searchTask?.cancel()
        self.searchTask = Task { await self.refresh() }
    }

    /// While the drawer is visible, any store change (background enrichment,
    /// a new copy, an expiring secret) re-runs the current query so cards
    /// update in place. Selection follows the selected item.
    public func startLiveUpdates() {
        guard self.liveUpdateTask == nil else { return }
        self.liveUpdateTask = Task {
            var isInitialEmission = true
            do {
                // A single copy lands as ingest + OCR + enrichment writes in
                // quick succession; debounce folds them into one refresh.
                for try await _ in self.store.observeChangeToken().debounce(for: .milliseconds(100)) {
                    // prepareForShow already loaded the initial list.
                    if isInitialEmission {
                        isInitialEmission = false
                        continue
                    }
                    let selectedID: String? = self.mode == .history
                        && self.items.indices.contains(self.selectedIndex)
                        ? self.items[self.selectedIndex].id : nil
                    await self.refresh(resetSelection: false, followItemID: selectedID)
                }
            } catch {
                // Observation only fails if the database is gone.
            }
        }
    }

    public func stopLiveUpdates() {
        self.liveUpdateTask?.cancel()
        self.liveUpdateTask = nil
    }

    public func toggleMode() {
        self.mode = self.mode == .history ? .snippets : .history
        self.query = ""
        self.selectedIndex = 0
        self.multiSelection = []
        self.searchTask?.cancel()
        self.searchTask = Task { await self.refresh() }
    }

    public func scheduleSearch() {
        Task { [searchChannel] in await searchChannel.send(()) }
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
                    // Must satisfy the query's operators too.
                    let parsed = ParsedQuery.parse(trimmed)
                    if parsed.text.count >= 4 {
                        let extras = await (try? self.store.semanticSearch(parsed.text, limit: 8)) ?? []
                        let seen = Set(results.map(\.id))
                        results += extras.filter { !seen.contains($0.id) && parsed.matches($0) }
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
                self.multiSelection = []
            } else {
                self.selectedIndex = min(self.selectedIndex, max(self.entryCount - 1, 0))
                self.multiSelection = self.multiSelection.filter { self.items.indices.contains($0) }
            }
            // A live update may have removed the item being previewed.
            if self.previewState != .hidden, self.selectedItem == nil {
                self.closePreview()
            }
        } catch {
            self.items = []
            self.snippets = []
        }
    }

    public func moveSelection(_ delta: Int) {
        guard self.entryCount > 0 else { return }
        self.collapseMultiSelection()
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

    public func selectAITransformed(at index: Int, transform: AITransform) {
        guard self.mode == .history, self.items.indices.contains(index) else { return }
        self.selectedIndex = index
        self.onCommitAITransform(self.items[index], transform)
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
