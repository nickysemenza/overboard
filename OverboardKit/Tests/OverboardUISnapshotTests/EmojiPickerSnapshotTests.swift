import OverboardCore
import OverboardMac
@testable import OverboardUI
import SnapshotTesting
import SwiftUI
import Testing

@MainActor
struct EmojiPickerSnapshotTests {
    /// Category sections with headers, first cell selected.
    @Test func categoryGrid() {
        let view = EmojiPickerView(viewModel: Fixtures.emojiPickerViewModel())
        assertSnapshot(
            of: snapshotImage(view, width: 400, height: 460),
            as: snapshotImageStrategy,
            record: snapshotRecordingMode
        )
    }
}

/// Render + commit-routing checks that don't compare pixels; mirrors
/// the LauncherCommitRouting suites' role for the launcher.
@MainActor
struct EmojiPickerLogicTests {
    private func rendersNonEmpty(_ image: NSImage) -> Bool {
        image.size.width > 0 && image.size.height > 0
    }

    @Test func pickerRendersHeadlessly() {
        let view = EmojiPickerView(viewModel: Fixtures.emojiPickerViewModel(recents: ["🔥"]))
        #expect(self.rendersNonEmpty(snapshotImage(view, width: 400, height: 460)))
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
