import OverboardCore
@testable import OverboardUI
import SnapshotTesting
import SwiftUI
import Testing

@Suite(.localOnly)
@MainActor
struct ItemCardSnapshotTests {
    private let store: ClipStore

    init() throws {
        self.store = try Fixtures.store()
    }

    /// 190×180 card plus margin for the selected state's scale and shadow.
    private func host(_ item: ClipItem, index: Int = 0, selected: Bool = false, dark: Bool = false) -> NSView {
        snapshotHost(
            ItemCardView(item: item, index: index, isSelected: selected, store: self.store),
            width: 220,
            height: 210,
            dark: dark
        )
    }

    @Test func plainText() {
        let item = Fixtures.item(preview: "Pick up the package before 6pm — front desk closes early on Fridays.")
        assertSnapshot(of: self.host(item), as: snapshotImageStrategy)
    }

    @Test func plainTextSelected() {
        let item = Fixtures.item(preview: "Pick up the package before 6pm — front desk closes early on Fridays.")
        assertSnapshot(of: self.host(item, selected: true), as: snapshotImageStrategy)
    }

    @Test func plainTextDark() {
        let item = Fixtures.item(preview: "Pick up the package before 6pm — front desk closes early on Fridays.")
        assertSnapshot(of: self.host(item, dark: true), as: snapshotImageStrategy)
    }

    @Test func aiEnriched() {
        let item = Fixtures.item(
            preview: "let total = items.reduce(0) { $0 + $1.byteSize }",
            aiTitle: "Sum of item sizes",
            category: "code",
            aiSummary: "Reduces clip items to their combined byte size."
        )
        assertSnapshot(of: self.host(item, index: 1), as: snapshotImageStrategy)
    }

    @Test func link() {
        let item = Fixtures.item(
            kind: .link,
            preview: "https://developer.apple.com/documentation/swiftui/imagerenderer"
        )
        assertSnapshot(of: self.host(item, index: 2), as: snapshotImageStrategy)
    }

    @Test func richLink() {
        let item = Fixtures.item(
            kind: .link,
            preview: "https://developer.apple.com/documentation/swiftui/imagerenderer",
            linkTitle: "ImageRenderer | Apple Developer Documentation",
            linkDescription: "An object that creates images from SwiftUI views.",
            faviconData: Fixtures.solidPNG(width: 32, height: 32, red: 0.2, green: 0.5, blue: 0.9),
            previewImageData: Fixtures.solidPNG(width: 240, height: 120, red: 0.85, green: 0.9, blue: 0.95)
        )
        assertSnapshot(of: self.host(item, index: 2), as: snapshotImageStrategy)
    }

    @Test func file() {
        let item = Fixtures.item(
            kind: .file,
            preview: "overboard-icon.sketch, release-notes.md",
            appName: "Finder"
        )
        assertSnapshot(of: self.host(item, index: 3), as: snapshotImageStrategy)
    }

    // MARK: - Metadata footers (v2)

    @Test func textWithFooter() {
        let item = Fixtures.item(
            preview: "Pick up the package before 6pm — front desk closes early on Fridays.",
            charCount: 1240,
            lineCount: 32
        )
        assertSnapshot(of: self.host(item), as: snapshotImageStrategy)
    }

    @Test func imageWithDimensions() {
        let item = Fixtures.item(
            kind: .image,
            preview: "Image 1920×1080",
            appName: "Preview",
            pixelWidth: 1920,
            pixelHeight: 1080
        )
        assertSnapshot(of: self.host(item, index: 5), as: snapshotImageStrategy)
    }

    @Test func fileWithFooter() {
        var item = Fixtures.item(
            kind: .file,
            preview: "overboard-icon.sketch, release-notes.md",
            appName: "Finder",
            fileCount: 2
        )
        item.byteSize = 2_100_000
        assertSnapshot(of: self.host(item, index: 3), as: snapshotImageStrategy)
    }

    @Test func secret() {
        let item = Fixtures.item(preview: "AWS access key", isSecret: true)
        assertSnapshot(of: self.host(item, index: 4), as: snapshotImageStrategy)
    }

    @Test func pinned() {
        let item = Fixtures.item(
            preview: "Overboard ⛵️ — everything you copy goes overboard.",
            isPinned: true
        )
        assertSnapshot(of: self.host(item), as: snapshotImageStrategy)
    }
}
