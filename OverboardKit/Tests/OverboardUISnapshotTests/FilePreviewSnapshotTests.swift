import AppKit
import Foundation
import OverboardFilePreview
import SnapshotTesting
import SwiftUI
import Testing

@Suite(.localOnly, .serialized)
@MainActor
struct FilePreviewSnapshotTests {
    private let markdown = FilePreviewContent(
        url: URL(fileURLWithPath: "/tmp/Preview.md"),
        text: "# Preview\n\nA [link](https://example.com).\n\n```swift\nlet highlighted = true\n```\n\n| One | Two |\n| --- | --- |\n| 1 | 2 |",
        language: nil, isMarkdown: true, isTruncated: false, fileSize: 112
    )

    @Test(arguments: [false, true])
    func renderedMarkdownInBothAppearances(dark: Bool) {
        let view = FilePreviewView(content: self.markdown)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = self.settledHost(view, dark: dark)
        assertSnapshot(
            of: host,
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
            of: snapshotHost(FilePreviewView(content: source), width: 520, height: 260),
            as: snapshotImageStrategy,
            record: snapshotRecordingMode
        )
    }

    private func settledHost(_ view: some View, dark: Bool) -> NSView {
        let host = snapshotHost(view, width: 520, height: 360, dark: dark)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        return host
    }
}
