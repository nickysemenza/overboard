import Foundation
import Observation
import OverboardCore
import OverboardMac

/// One header + run of emoji in the picker grid. `start` is the section's
/// flat start index in the concatenated grid and lives INSIDE the section
/// value on purpose: SwiftUI can re-evaluate a stale ForEach child (old
/// sectionIndex) after the section list shrinks, so a view closure must never
/// index a parallel array by section position — it reads its own captured
/// section, which is always self-consistent.
public struct EmojiSection: Identifiable, Sendable {
    public let title: String
    public let emoji: [Emoji]
    public let start: Int
    public var id: String {
        self.title
    }

    public init(title: String, emoji: [Emoji], start: Int) {
        self.title = title
        self.emoji = emoji
        self.start = start
    }
}

/// State for the emoji picker panel: query → sections, a flat selection index
/// over the grid, and commit routing. Same shape as LauncherViewModel but far
/// smaller — search is a synchronous in-memory filter, so there are no
/// providers, debounce, or streaming.
@MainActor
@Observable
public final class EmojiPickerViewModel {
    public var query = "" {
        didSet {
            if self.query != oldValue {
                self.updateResults()
            }
        }
    }

    public private(set) var sections: [EmojiSection] = []
    public var selectedIndex = 0
    /// Bumped on every show so the view can re-assert search-field focus.
    public private(set) var showGeneration = 0

    /// ↩ — paste into the summoning app.
    public var onPick: (Emoji) -> Void = { _ in }
    /// ⌘↩ — copy only.
    public var onCopy: (Emoji) -> Void = { _ in }

    /// Grid width; EmojiGridLayout and the view's LazyVGrid must agree.
    public static let columns = 8
    /// Search results are capped well past what anyone scans, but low enough
    /// that a single-letter query doesn't build a thousand-cell grid.
    private static let searchLimit = 120

    private let loadCatalog: @Sendable () -> EmojiCatalog
    private var catalog: EmojiCatalog?

    public init(catalog: @escaping @Sendable () -> EmojiCatalog) {
        self.loadCatalog = catalog
    }

    /// Decodes the catalog off the main actor so the first summon doesn't pay
    /// the JSON decode; `prepareForShow` falls back to a synchronous load if
    /// the picker opens before this finishes.
    public func warm() {
        guard self.catalog == nil else { return }
        let load = self.loadCatalog
        Task.detached(priority: .utility) { [weak self] in
            let catalog = load()
            await MainActor.run { [weak self] in
                guard let self, self.catalog == nil else { return }
                self.catalog = catalog
            }
        }
    }

    /// Fresh open every time: empty query, pruned recents, selection at the
    /// grid's first cell (deliberately no launcher-style resume window — picker
    /// queries are throwaway filter text).
    public func prepareForShow() {
        if self.catalog == nil {
            self.catalog = self.loadCatalog()
        }
        if let catalog {
            let pruned = EmojiRecents.pruned(Defaults[.emojiRecents], validCharacters: Set(catalog.byCharacter.keys))
            if pruned != Defaults[.emojiRecents] {
                Defaults[.emojiRecents] = pruned
            }
        }
        self.query = ""
        self.updateResults()
        self.showGeneration += 1
    }

    public func updateResults() {
        guard let catalog else {
            self.setSections([])
            return
        }
        let trimmed = self.query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            var runs: [(title: String, emoji: [Emoji])] = []
            let recents = Defaults[.emojiRecents].compactMap { catalog.byCharacter[$0] }
            if !recents.isEmpty {
                runs.append((title: "Recently Used", emoji: recents))
            }
            runs += catalog.byCategory.map { (title: $0.category.title, emoji: $0.emoji) }
            self.setSections(runs)
        } else {
            let ranked = EmojiMatcher.rank(query: trimmed, in: catalog.all, limit: Self.searchLimit)
            self.setSections(ranked.isEmpty ? [] : [(title: "Results", emoji: ranked)])
        }
    }

    // MARK: - Selection

    public var totalCount: Int {
        (self.sections.last?.start ?? 0) + (self.sections.last?.emoji.count ?? 0)
    }

    public var selectedEmoji: Emoji? {
        self.emoji(at: self.selectedIndex)
    }

    /// Scroll anchor for the selected cell — namespaced by section because an
    /// emoji can appear both in Recently Used and its home category.
    public var selectedCellID: String? {
        guard let position = self.position(of: self.selectedIndex) else { return nil }
        return Self.cellID(section: position.section, character: self.sections[position.section].emoji[position.offset].character)
    }

    public static func cellID(section: Int, character: String) -> String {
        "\(section)-\(character)"
    }

    public func moveSelection(_ direction: EmojiGridLayout.Direction) {
        let layout = EmojiGridLayout(sectionCounts: self.sections.map(\.emoji.count), columns: Self.columns)
        self.selectedIndex = layout.move(from: self.selectedIndex, direction)
    }

    /// Records the pick into recents, then routes to paste (↩) or copy (⌘↩).
    public func commit(copyOnly: Bool) {
        guard let emoji = self.selectedEmoji else { return }
        Defaults[.emojiRecents] = EmojiRecents.recording(emoji.character, into: Defaults[.emojiRecents])
        if copyOnly {
            self.onCopy(emoji)
        } else {
            self.onPick(emoji)
        }
    }

    private func emoji(at flatIndex: Int) -> Emoji? {
        guard let position = self.position(of: flatIndex) else { return nil }
        return self.sections[position.section].emoji[position.offset]
    }

    private func position(of flatIndex: Int) -> (section: Int, offset: Int)? {
        guard flatIndex >= 0 else { return nil }
        for (section, run) in self.sections.enumerated() {
            let offset = flatIndex - run.start
            if offset >= 0, offset < run.emoji.count {
                return (section, offset)
            }
        }
        return nil
    }

    private func setSections(_ runs: [(title: String, emoji: [Emoji])]) {
        var sections: [EmojiSection] = []
        var running = 0
        for run in runs {
            sections.append(EmojiSection(title: run.title, emoji: run.emoji, start: running))
            running += run.emoji.count
        }
        self.sections = sections
        self.selectedIndex = 0
    }
}
