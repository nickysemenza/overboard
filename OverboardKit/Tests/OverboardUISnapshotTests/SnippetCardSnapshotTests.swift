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

    @Test func plain() {
        let view = SnippetCardView(
            snippet: self.snippet(title: "Sign-off", body: "Best,\nNicky"),
            index: 0,
            isSelected: false
        )
        assertSnapshot(of: snapshotHost(view, width: 220, height: 210), as: snapshotImageStrategy)
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
        assertSnapshot(of: snapshotHost(view, width: 220, height: 210), as: snapshotImageStrategy)
    }
}
