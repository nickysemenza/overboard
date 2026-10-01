import AppKit
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

    @Test func searchHeaderRemainsStableAcrossMountedLayoutPasses() async throws {
        _ = NSApplication.shared
        let model = Fixtures.emojiPickerViewModel()
        let view = EmojiPickerView(viewModel: model)
        let host = snapshotHost(view, width: 400, height: 460)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 460),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        let field = try #require(self.textFields(in: host).first)
        #expect(window.makeFirstResponder(field))
        let originalFrame = field.convert(field.bounds, to: host)
        #expect(originalFrame.minY == 26)
        #expect(originalFrame.height == 20)
        for query in ["fire", "", "pizza", ""] {
            model.query = query
            field.invalidateIntrinsicContentSize()
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
            host.layoutSubtreeIfNeeded()
            #expect(field.convert(field.bounds, to: host) == originalFrame)
        }
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { self.textFields(in: $0) }
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
