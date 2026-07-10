import AppKit
import OverboardCore
@testable import OverboardUI
import SwiftUI
import Testing

/// CI-safe counterpart to the (local-only) snapshot suites: it renders the card
/// view bodies headlessly and asserts they produce a non-empty image, without
/// the Retina-sensitive pixel comparison. This catches crashes, force-unwraps,
/// and layout traps in the render paths on CI, where the image assertions are
/// skipped. Not marked `.localOnly` — it runs everywhere.
@MainActor
struct RenderSmokeTests {
    private let store: ClipStore

    init() throws {
        self.store = try Fixtures.store()
    }

    /// Renders the laid-out view to a bitmap and confirms it has real pixels —
    /// which forces the SwiftUI body to evaluate and draw.
    private func rendersNonEmpty(_ view: NSView) -> Bool {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.pixelsWide > 0 && rep.pixelsHigh > 0
    }

    private func card(_ item: ClipItem, selected: Bool = false, dark: Bool = false) -> NSView {
        snapshotHost(
            ItemCardView(item: item, index: 0, isSelected: selected, store: self.store),
            width: 220, height: 210, dark: dark
        )
    }

    @Test func itemCardRendersEveryKind() {
        let items: [ClipItem] = [
            Fixtures.item(kind: .text, preview: "a plain text clip", charCount: 17, lineCount: 1),
            Fixtures.item(kind: .link, preview: "https://example.com", linkTitle: "Example"),
            Fixtures.item(kind: .image, preview: "Image 800×600", pixelWidth: 800, pixelHeight: 600),
            Fixtures.item(kind: .file, preview: "notes.md", fileCount: 1),
            Fixtures.item(kind: .color, preview: "#3366FF"),
            Fixtures.item(preview: "a pinned clip", isPinned: true),
            Fixtures.item(preview: "Secret — API token", isSecret: true),
        ]
        for item in items {
            #expect(self.rendersNonEmpty(self.card(item)), "card failed to render: \(item.previewText ?? "")")
        }
    }

    @Test func itemCardRendersSelectedAndDark() {
        let item = Fixtures.item(preview: "selection + dark mode")
        #expect(self.rendersNonEmpty(self.card(item, selected: true)))
        #expect(self.rendersNonEmpty(self.card(item, dark: true)))
    }

    @Test func snippetCardRenders() {
        let snippet = Snippet(
            id: "smoke",
            title: "Sign-off",
            body: "Best,\nNicky",
            createdAt: Fixtures.date,
            updatedAt: Fixtures.date
        )
        let view = SnippetCardView(snippet: snippet, index: 0, isSelected: false)
        #expect(self.rendersNonEmpty(snapshotHost(view, width: 220, height: 210)))
    }
}
