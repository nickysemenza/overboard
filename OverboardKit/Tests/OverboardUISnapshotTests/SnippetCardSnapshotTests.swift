import OverboardCore
@testable import OverboardUI
import SnapshotTesting
import SwiftUI
import Testing

@MainActor
struct SnippetCardSnapshotTests {
    private func snippet(title: String, body: String) -> Snippet {
        Snippet(
            id: "fixture-\(title)",
            title: title,
            body: body,
            createdAt: Fixtures.date,
            updatedAt: Fixtures.date
        )
    }

    @Test func selectedWithPlaceholders() {
        let view = SnippetCardView(
            snippet: self.snippet(
                title: "Bug report",
                body: "Seen on {date} — build {uuid}. Steps to reproduce:"
            ),
            index: 1,
            isSelected: true
        )
        assertSnapshot(
            of: snapshotImage(view, width: 220, height: 210),
            as: snapshotImageStrategy,
            record: snapshotRecordingMode
        )
    }
}
