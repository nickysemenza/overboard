import AsyncAlgorithms
import Foundation
import Observation
import os
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

@Observable
public final class DrawerViewModel {
    /// `internal(set)`: mutated from `deleteSelected()` in the actions
    /// extension in another file, in addition to `refresh` in this file.
    public internal(set) var items: [ClipItem] = []
    public private(set) var snippets: [Snippet] = []
    public private(set) var mode: DrawerMode = .history
    public var query: String = ""
    public var selectedIndex: Int = 0
    /// Extra selected indices beyond the anchor (⇧arrows / ⌘-click). Empty
    /// means plain single selection. `internal(set)`: mutated from the
    /// multi-selection and paste-action extensions in other files.
    public internal(set) var multiSelection: Set<Int> = []

    let logger = Logger(subsystem: "com.nickysemenza.overboard", category: "drawer")

    public let stack: PasteStack

    /// Called when the user commits an item (Return, click, ⌘n).
    public var onCommit: (ClipItem, PasteMode) -> Void = { _, _ in }
    public var onCommitSnippet: (Snippet) -> Void = { _ in }
    public var onCommitTransform: (ClipItem, ClipTransform) -> Void = { _, _ in }
    public var onCommitAITransform: (ClipItem, AITransform) -> Void = { _, _ in }
    public var onDismiss: () -> Void = {}
    public var onBrowseHistory: () -> Void = {}
    /// Set by DrawerView, which owns the SwiftUI openSettings environment action.
    public var onOpenSettings: () -> Void = {}
    /// Runs a clip action against the selected items.
    public var onRunAction: (ClipAction, [ClipItem]) -> Void = { _, _ in }

    // MARK: - ⌘K palette state (behavior in DrawerViewModel+Palette.swift)

    /// `internal(set)`: mutated from the palette extension in another file.
    public internal(set) var isPaletteOpen = false
    public var paletteQuery: String = ""
    public var paletteIndex: Int = 0

    // MARK: - Preview / edit state (behavior in DrawerViewModel+Preview.swift)

    /// `internal(set)`: mutated from the preview/edit extension in another file.
    public internal(set) var previewState: PreviewState = .hidden
    public var editText: String = ""
    /// Pastes user-edited text instead of the original item.
    public var onCommitEditedText: (String) -> Void = { _ in }
    /// The controller resizes the panel when the preview pane opens/closes.
    public var onPreviewVisibilityChanged: (Bool) -> Void = { _ in }

    let store: ClipStore
    /// `internal`: cancelled and restarted from `jump(toItemID:)` in the
    /// multi-selection extension, in addition to this file.
    var searchTask: Task<Void, Never>?
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

    /// Re-runs the current query. `internal`: also called from the
    /// multi-selection (`jump(toItemID:)`) and paste-action
    /// (`togglePinSelected`/`deleteSelected`) extensions in other files.
    func refresh(resetSelection: Bool = true, followItemID: String? = nil) async {
        // Capture the multi-selected rows' identities before the list is
        // replaced, so a live update that inserts/removes rows moves the
        // selection with its items instead of leaving stale indices that would
        // make a multi-item action operate on rows the user never picked.
        let priorMultiIDs = Set(
            self.multiSelection
                .filter { self.items.indices.contains($0) }
                .map { self.items[$0].id }
        )
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
                self.multiSelection = self.remapSelection(to: priorMultiIDs)
            } else if resetSelection {
                self.selectedIndex = 0
                self.multiSelection = []
            } else {
                self.selectedIndex = min(self.selectedIndex, max(self.entryCount - 1, 0))
                self.multiSelection = self.remapSelection(to: priorMultiIDs)
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
}
