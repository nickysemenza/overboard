import AppKit
import OverboardCore
import OverboardFilePreview
import OverboardMac
@testable import OverboardUI
import SwiftUI
import Testing

/// Breadth counterpart to the pixel suites: it renders view bodies the
/// recorded snapshots don't cover — every launcher scope, both appearances,
/// each file-preview variant — and only asserts they produce a non-empty
/// image. Catching a crash, force-unwrap, or layout trap in those paths is
/// worth far less ceremony than a reference PNG per combination.
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

    @Test func launcherScopesRenderInBothAppearances() async {
        let model = LauncherViewModel(instantProviders: [StubLauncherProvider(rows: [
            .file(name: "2026 budget.xlsx", url: URL(fileURLWithPath: "/fixture/iCloud Drive/Wedding/2026 budget.xlsx"), info: FileSearchInfo(availability: .cloud)),
            .clip(Fixtures.item(preview: "Wedding budget notes")),
        ])], secondaryProviders: [])
        model.query = "wedding budget"
        for scope in LauncherScope.allCases {
            model.scope = scope
            model.scheduleSearch()
            await model.settle()
            for dark in [false, true] {
                let view = LauncherView(viewModel: model, store: self.store)
                #expect(self.rendersNonEmpty(snapshotHost(view, width: model.showsPreview ? 1020 : 740, height: 650, dark: dark)))
            }
        }
    }

    @Test func welcomeRendersInBothAppearances() {
        for dark in [false, true] {
            let view = WelcomeView(
                permissions: PermissionService(accessibility: .denied),
                openShortcutSettings: {},
                onDone: {}
            )
            #expect(self.rendersNonEmpty(snapshotHost(view, width: 460, height: 520, dark: dark)))
        }
    }

    @Test func permissionsTabRendersEveryState() {
        let view = PermissionsSettingsTab(
            permissions: PermissionService(
                accessibility: .granted,
                automation: ["com.apple.Safari": .granted, "com.google.Chrome": .denied]
            ),
            fileIssues: { ["/Users/overboard/Library/Mail: Permission denied.", "File index unavailable."] }
        )
        #expect(self.rendersNonEmpty(snapshotHost(view, width: 560, height: 520)))
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

    @Test func filePreviewsRenderInBothAppearances() {
        let source = FilePreviewContent(
            url: URL(fileURLWithPath: "/tmp/Preview.swift"), text: "let preview = true\n",
            language: "swift", isMarkdown: false, isTruncated: false, fileSize: 19
        )
        let markdown = FilePreviewContent(
            url: URL(fileURLWithPath: "/tmp/Preview.md"),
            text: "# Preview\n\n```swift\nlet highlighted = true\n```\n\n| One | Two |\n| --- | --- |\n| 1 | 2 |",
            language: nil, isMarkdown: true, isTruncated: true, fileSize: 96
        )
        for content in [source, markdown] {
            for dark in [false, true] {
                #expect(self.rendersNonEmpty(snapshotHost(FilePreviewView(content: content), width: 520, height: 360, dark: dark)))
            }
        }
    }
}
