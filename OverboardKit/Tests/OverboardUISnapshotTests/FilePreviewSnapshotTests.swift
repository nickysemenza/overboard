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

    @Test(arguments: [false, true])
    func renderedMarkdownInBothAppearances(dark: Bool) {
        let view = FilePreviewView(content: self.markdown)
            .environment(\.colorScheme, dark ? .dark : .light)
        assertSnapshot(
            of: self.settledImage(view, height: 360, dark: dark),
            as: snapshotImageStrategy,
            record: snapshotRecordingMode
        )
    }

    @Test func truncatedSwiftSource() {
        let source = FilePreviewContent(
            url: URL(fileURLWithPath: "/tmp/Preview.swift"), text: "let preview = true\n",
            language: "swift", isMarkdown: false, isTruncated: true, fileSize: 19
        )
        assertSnapshot(
            of: self.settledImage(FilePreviewView(content: source), height: 260),
            as: snapshotImageStrategy,
            record: snapshotRecordingMode
        )
    }

    /// The preview lays its scrolling content out over a turn of the run loop,
    /// so the host needs one before there's anything to capture. Every case
    /// goes through this, the plain-source one included, so all three are
    /// captured from the same settled state.
    ///
    /// The source case renders unhighlighted on purpose: `FilePreviewView`
    /// fetches its highlighted string from a `.task`, and a `.task` never fires
    /// for an `NSHostingView` that was never put in a window — so headless,
    /// this view is always its plain-`Text` fallback. That's stable, which is
    /// what a snapshot needs; `HighlightrCache` itself is covered by the
    /// markdown cases above, which highlight synchronously.
    private func settledImage(_ view: some View, height: CGFloat, dark: Bool = false) -> NSImage {
        let host = snapshotHost(view, width: 520, height: height, dark: dark)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        return capture(host)
    }
}
