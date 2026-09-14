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

/// One strip card: the item plus the ranking hint the card shows. Derived
/// once per refresh and carried *in* the element — never looked up by
/// ForEach position, which SwiftUI may re-evaluate against a stale array.
/// `nonisolated`: plain data, so `StripEntryTests` can build and compare it
/// from a synchronous, non-`@MainActor` test function.
public nonisolated struct StripEntry: Identifiable, Equatable {
    public let item: ClipItem
    public let rankedAboveNewer: Bool
    public var id: String {
        self.item.id
    }
}

@Observable
public final class DrawerViewModel {
    /// `internal(set)`: mutated from `deleteSelected()` in the actions
    /// extension in another file, in addition to `refresh` in this file.
    /// `didSet` keeps `stripEntries` in sync with every assignment (full
    /// replacement in `refresh`, the optimistic removal in `deleteSelected`)
    /// instead of relying on each call site to remember the second property.
    public internal(set) var items: [ClipItem] = [] {
        didSet { self.stripEntries = Self.stripEntries(for: self.items) }
    }

    /// The card strip's actual iteration target — `items` plus the "ranked
    /// above a newer item" hint each card renders. Kept as a real stored
    /// property (not computed on read) so it's the same array `ForEach`
    /// diffs and identity-tracks across refreshes.
    public private(set) var stripEntries: [StripEntry] = []
    public private(set) var snippets: [Snippet] = []
    public private(set) var mode: DrawerMode = .history
    public var query: String = ""
    /// The frontmost app's name when the drawer was summoned — the footer's
    /// "Paste to …" label and paste destination. Set by `OverlayController`,
    /// the same way `LauncherPanelController.show(…)` sets the launcher's.
    public var targetAppName: String = .init(localized: "previous app", bundle: .module)
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
    /// Height of the drawer's glass shell in the collapsed state, reported by
    /// `DrawerView` from its own layout so the controller can size the panel
    /// to what the content actually needs (the saved-search chip bar comes
    /// and goes). `nil` until the drawer has laid out once.
    public internal(set) var collapsedShellHeight: CGFloat?

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

    /// Flags every unpinned item that sits above a strictly newer one in
    /// `items` — the frecency blend's designed-in reordering (see
    /// `ClipStore.frecencyOrderSQL`), made visible instead of read as a
    /// mis-sort. A single backward pass tracks the newest `lastUsedAt` seen
    /// among later entries (a suffix max); an entry is flagged the moment
    /// that running max exceeds its own timestamp. `static`, `nonisolated`,
    /// and pure so it's testable without a `ClipStore` or the main actor.
    nonisolated static func stripEntries(for items: [ClipItem]) -> [StripEntry] {
        var entries: [StripEntry] = []
        entries.reserveCapacity(items.count)
        var newestAmongLater: Date?
        for item in items.reversed() {
            let rankedAboveNewer = !item.isPinned && (newestAmongLater.map { $0 > item.lastUsedAt } ?? false)
            entries.append(StripEntry(item: item, rankedAboveNewer: rankedAboveNewer))
            newestAmongLater = max(newestAmongLater ?? item.lastUsedAt, item.lastUsedAt)
        }
        return Array(entries.reversed())
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
