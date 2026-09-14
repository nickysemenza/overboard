import AppKit
import Foundation
import OverboardFilePreview
import SnapshotTesting
import SwiftUI
import Testing

@Suite(.serialized)
@MainActor
struct FilePreviewSnapshotTests {
    private let markdown = FilePreviewContent(
        url: URL(fileURLWithPath: "/tmp/Preview.md"),
        text: "# Preview\n\nA [link](https://example.com).\n\n```swift\nlet highlighted = true\n```\n\n"
            + "| One | Two |\n| --- | --- |\n| 1 | 2 |",
        language: nil, isMarkdown: true, isTruncated: false, fileSize: 112
    )

    @Test func renderedMarkdown() {
        assertSnapshot(
            of: self.settledImage(FilePreviewView(content: self.markdown), height: 360),
            as: snapshotImageStrategy,
            record: snapshotRecordingMode
        )
    }

    /// The preview lays its scrolling content out over a turn of the run loop,
    /// so the host needs one before there's anything to capture. Markdown
    /// highlights synchronously, so this one image also covers `HighlightrCache`.
    private func settledImage(_ view: some View, height: CGFloat) -> NSImage {
        let host = snapshotHost(view, width: 520, height: height)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        return capture(host)
    }
}
