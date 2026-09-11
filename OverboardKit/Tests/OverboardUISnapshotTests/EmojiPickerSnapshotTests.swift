import OverboardCore
import OverboardMac
@testable import OverboardUI
import SnapshotTesting
import SwiftUI
import Testing

@Suite(.localOnly)
@MainActor
struct EmojiPickerSnapshotTests {
    /// Category sections with headers, first cell selected.
    @Test func categoryGrid() {
        let view = EmojiPickerView(viewModel: Fixtures.emojiPickerViewModel())
        assertSnapshot(of: snapshotHost(view, width: 400, height: 460), as: snapshotImageStrategy)
    }

    /// A Recently Used section leads when recents exist and the query is empty.
    @Test func recentlyUsedLeads() {
        let view = EmojiPickerView(viewModel: Fixtures.emojiPickerViewModel(recents: ["🔥", "🍕", "👍"]))
        assertSnapshot(of: snapshotHost(view, width: 400, height: 460), as: snapshotImageStrategy)
    }

    /// Search collapses to a single ranked Results section.
    @Test func searchResults() {
        let viewModel = Fixtures.emojiPickerViewModel()
        viewModel.query = "lo"
        let view = EmojiPickerView(viewModel: viewModel)
        assertSnapshot(of: snapshotHost(view, width: 400, height: 460), as: snapshotImageStrategy)
    }

    /// No matches shows the placeholder, not an empty grid.
    @Test func emptyState() {
        let viewModel = Fixtures.emojiPickerViewModel()
        viewModel.query = "zzzzzz"
        let view = EmojiPickerView(viewModel: viewModel)
        assertSnapshot(of: snapshotHost(view, width: 400, height: 460), as: snapshotImageStrategy)
    }

    @Test func categoryGridDark() {
        let view = EmojiPickerView(viewModel: Fixtures.emojiPickerViewModel())
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
        let view = EmojiPickerView(viewModel: Fixtures.emojiPickerViewModel(recents: ["🔥"]))
        #expect(self.rendersNonEmpty(snapshotHost(view, width: 400, height: 460)))
    }

    @Test func commitRoutesReturnToPickAndCommandReturnToCopy() {
        let viewModel = Fixtures.emojiPickerViewModel()
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
        let viewModel = Fixtures.emojiPickerViewModel()
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
        let viewModel = Fixtures.emojiPickerViewModel(recents: ["🔥", "🦖🦖"]) // second not in catalog
        #expect(Defaults[.emojiRecents] == ["🔥"])
        #expect(viewModel.sections.first?.emoji.map(\.character) == ["🔥"])
    }

    @Test func selectionMovesAcrossTheGrid() {
        let viewModel = Fixtures.emojiPickerViewModel()
        #expect(viewModel.selectedIndex == 0)
        viewModel.moveSelection(.right)
        #expect(viewModel.selectedIndex == 1)
        viewModel.moveSelection(.left)
        viewModel.moveSelection(.left) // clamped at the first cell
        #expect(viewModel.selectedIndex == 0)
    }
}
