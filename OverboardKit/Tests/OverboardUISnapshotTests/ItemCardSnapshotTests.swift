import OverboardCore
@testable import OverboardUI
import SnapshotTesting
import SwiftUI
import Testing

/// Visual smoke for the clipboard card: one selected text card with a full
/// footer, the one card body that isn't text, the one warning treatment, and
/// the accessibility-size layout. Ordinary text/link/file cards are covered by
/// `DrawerSnapshotTests`; footer composition is unit-tested in Core.
@MainActor
struct ItemCardSnapshotTests {
    private let store: ClipStore

    init() throws {
        self.store = try Fixtures.store()
    }

    /// 190×180 card plus margin for the selected state's scale and shadow.
    private func host(_ item: ClipItem, index: Int = 0, selected: Bool = false) -> NSImage {
        snapshotImage(
            ItemCardView(item: item, index: index, isSelected: selected, store: self.store),
            width: 220,
            height: 210
        )
    }

    @Test func selectedTextWithFooter() {
        let item = Fixtures.item(
            preview: "Pick up the package before 6pm — front desk closes early on Fridays.",
            charCount: 1240,
            lineCount: 32
        )
        assertSnapshot(of: self.host(item, selected: true), as: snapshotImageStrategy, record: snapshotRecordingMode)
    }

    @Test func imageWithDimensions() {
        let item = Fixtures.item(
            kind: .image,
            preview: "Image 1920×1080",
            appName: "Preview",
            pixelWidth: 1920,
            pixelHeight: 1080
        )
        assertSnapshot(of: self.host(item, index: 5), as: snapshotImageStrategy, record: snapshotRecordingMode)
    }

    @Test func secret() {
        let item = Fixtures.item(preview: "AWS access key", isSecret: true)
        assertSnapshot(of: self.host(item, index: 4), as: snapshotImageStrategy, record: snapshotRecordingMode)
    }

    /// Pins the accessibility-text layout: the card's own geometry scales with
    /// Dynamic Type and the preview's line budget shrinks to match, so nothing
    /// spills past the tile.
    @Test func largestDynamicType() {
        let item = Fixtures.item(
            preview: "Pick up the package before 6pm — front desk closes early on Fridays.",
            charCount: 1240,
            lineCount: 32
        )
        let view = ItemCardView(item: item, index: 0, isSelected: false, store: self.store)
            .environment(\.dynamicTypeSize, .xxxLarge)
        assertSnapshot(
            of: snapshotImage(view, width: 300, height: 300),
            as: snapshotImageStrategy,
            record: snapshotRecordingMode
        )
    }
}
