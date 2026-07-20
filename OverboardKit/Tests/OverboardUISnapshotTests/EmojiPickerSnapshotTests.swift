import OverboardCore
import OverboardMac
@testable import OverboardUI
import SnapshotTesting
import SwiftUI
import Testing

/// A small fixed catalog of long-stable emoji (Unicode 6-era) — snapshotting
/// the real 1,900-glyph dataset would tie the images to whichever Apple Color
/// Emoji revision the recording Mac has. Nonisolated so the view model's
/// `@Sendable` catalog closure can call it.
private func fixtureCatalog() -> EmojiCatalog {
    func emoji(_ character: String, _ name: String, _ category: EmojiCategory, keywords: [String] = []) -> Emoji {
        Emoji(character: character, name: name, keywords: keywords, category: category, version: 0.6)
    }
    return EmojiCatalog(all: [
        emoji("😀", "grinning face", .smileys, keywords: ["smile", "happy"]),
        emoji("😂", "face with tears of joy", .smileys, keywords: ["laugh"]),
        emoji("😍", "smiling face with heart-eyes", .smileys, keywords: ["love"]),
        emoji("🙃", "upside-down face", .smileys),
        emoji("😴", "sleeping face", .smileys, keywords: ["zzz"]),
        emoji("👍", "thumbs up", .people, keywords: ["approve", "yes"]),
        emoji("👋", "waving hand", .people, keywords: ["hello"]),
        emoji("💪", "flexed biceps", .people, keywords: ["strong"]),
        emoji("🐶", "dog face", .animals, keywords: ["puppy"]),
        emoji("🐱", "cat face", .animals, keywords: ["kitten"]),
        emoji("🌵", "cactus", .animals),
        emoji("🍕", "pizza", .food, keywords: ["slice"]),
        emoji("🍣", "sushi", .food),
        emoji("☕", "hot beverage", .food, keywords: ["coffee", "tea"]),
        emoji("🚀", "rocket", .travel, keywords: ["launch", "space"]),
        emoji("🔥", "fire", .travel, keywords: ["flame", "hot"]),
        emoji("⚽", "soccer ball", .activities, keywords: ["football"]),
        emoji("🎉", "party popper", .activities, keywords: ["celebrate"]),
        emoji("💡", "light bulb", .objects, keywords: ["idea"]),
        emoji("📎", "paperclip", .objects),
        emoji("❤️", "red heart", .symbols, keywords: ["love"]),
        emoji("✅", "check mark button", .symbols, keywords: ["done"]),
        emoji("🏁", "chequered flag", .flags, keywords: ["race"]),
        emoji("🏳️", "white flag", .flags, keywords: ["surrender"]),
    ])
}

@MainActor
private func makeViewModel(recents: [String] = []) -> EmojiPickerViewModel {
    // Pin the shared recents key so the machine's real picks can't leak into
    // the deterministic fixtures.
    Defaults[.emojiRecents] = recents
    let viewModel = EmojiPickerViewModel(catalog: { fixtureCatalog() })
    viewModel.prepareForShow()
    return viewModel
}

@Suite(.localOnly)
@MainActor
struct EmojiPickerSnapshotTests {
    /// Category sections with headers, first cell selected.
    @Test func categoryGrid() {
        let view = EmojiPickerView(viewModel: makeViewModel())
        assertSnapshot(of: snapshotHost(view, width: 400, height: 460), as: snapshotImageStrategy)
    }

    /// A Recently Used section leads when recents exist and the query is empty.
    @Test func recentlyUsedLeads() {
        let view = EmojiPickerView(viewModel: makeViewModel(recents: ["🔥", "🍕", "👍"]))
        assertSnapshot(of: snapshotHost(view, width: 400, height: 460), as: snapshotImageStrategy)
    }

    /// Search collapses to a single ranked Results section.
    @Test func searchResults() {
        let viewModel = makeViewModel()
        viewModel.query = "lo"
        let view = EmojiPickerView(viewModel: viewModel)
        assertSnapshot(of: snapshotHost(view, width: 400, height: 460), as: snapshotImageStrategy)
    }

    /// No matches shows the placeholder, not an empty grid.
    @Test func emptyState() {
        let viewModel = makeViewModel()
        viewModel.query = "zzzzzz"
        let view = EmojiPickerView(viewModel: viewModel)
        assertSnapshot(of: snapshotHost(view, width: 400, height: 460), as: snapshotImageStrategy)
    }

    @Test func categoryGridDark() {
        let view = EmojiPickerView(viewModel: makeViewModel())
        assertSnapshot(of: snapshotHost(view, width: 400, height: 460, dark: true), as: snapshotImageStrategy)
    }
}

/// CI-safe render + commit-routing checks (the image suites above are
/// local-only); mirrors LauncherCommitRoutingTests' role for the launcher.
@MainActor
struct EmojiPickerLogicTests {
    private func rendersNonEmpty(_ view: NSView) -> Bool {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.pixelsWide > 0 && rep.pixelsHigh > 0
    }

    @Test func pickerRendersHeadlessly() {
        let view = EmojiPickerView(viewModel: makeViewModel(recents: ["🔥"]))
        #expect(self.rendersNonEmpty(snapshotHost(view, width: 400, height: 460)))
    }

    @Test func commitRoutesReturnToPickAndCommandReturnToCopy() {
        let viewModel = makeViewModel()
        var picked: [String] = []
        var copied: [String] = []
        viewModel.onPick = { picked.append($0.character) }
        viewModel.onCopy = { copied.append($0.character) }

        viewModel.query = "fire"
        viewModel.commit(copyOnly: false)
        viewModel.commit(copyOnly: true)
        #expect(picked == ["🔥"])
        #expect(copied == ["🔥"])
    }

    @Test func commitRecordsRecentsMostRecentFirst() {
        let viewModel = makeViewModel()
        viewModel.onPick = { _ in }
        viewModel.query = "fire"
        viewModel.commit(copyOnly: false)
        viewModel.query = "pizza"
        viewModel.commit(copyOnly: false)
        #expect(Defaults[.emojiRecents] == ["🍕", "🔥"])

        // Reopening surfaces them as the leading section.
        viewModel.prepareForShow()
        #expect(viewModel.sections.first?.title == "Recently Used")
        #expect(viewModel.sections.first?.emoji.map(\.character) == ["🍕", "🔥"])
    }

    @Test func staleRecentsArePrunedOnShow() {
        let viewModel = makeViewModel(recents: ["🔥", "🦖🦖"]) // second not in catalog
        #expect(Defaults[.emojiRecents] == ["🔥"])
        #expect(viewModel.sections.first?.emoji.map(\.character) == ["🔥"])
    }

    @Test func selectionMovesAcrossTheGrid() {
        let viewModel = makeViewModel()
        #expect(viewModel.selectedIndex == 0)
        viewModel.moveSelection(.right)
        #expect(viewModel.selectedIndex == 1)
        viewModel.moveSelection(.left)
        viewModel.moveSelection(.left) // clamped at the first cell
        #expect(viewModel.selectedIndex == 0)
    }
}
