import Foundation
import OverboardCore
import OverboardMac
@testable import OverboardUI
import Testing

/// Pure logic, no snapshots — runs on CI too. Clip/snippet routing and the
/// ⌘K action palette (predominantly exercised against clip rows). Split out
/// of `LauncherCommitRoutingTests` by routed result kind.
@Suite(.serialized)
@MainActor
struct LauncherCommitRoutingClipTests {
    @Test func clipRowRoutesPerModifier() async {
        let item = Fixtures.item(preview: "deploy checklist")
        let viewModel = await LauncherCommitRoutingFixtures.makeViewModel(rows: [.clip(item)])

        var pasted: [(String, PasteMode)] = []
        var copied: [String] = []
        viewModel.onPasteClip = { pasted.append(($0.id, $1)) }
        viewModel.onCopyClip = { copied.append($0.id) }

        viewModel.commit()
        viewModel.commit(modifier: .option)
        viewModel.commit(modifier: .command)

        #expect(pasted.map(\.0) == [item.id, item.id])
        #expect(pasted.map(\.1) == [.full, .plainText])
        #expect(copied == [item.id])
    }

    @Test func performOpensLinkClip() async {
        let item = Fixtures.item(kind: .link, preview: " https://example.com ")
        let viewModel = await LauncherCommitRoutingFixtures.makeViewModel(rows: [.clip(item)])

        var opened: [URL] = []
        viewModel.onOpenClipLink = { opened.append($0) }

        viewModel.perform(.openLink)

        #expect(opened == [URL(string: "https://example.com")])
    }

    /// A whitespace-only link clip yields no open — the URL parse fails safely
    /// (matches `ClipAction.openLink`'s permissive `URL(string:)` behavior).
    @Test func performIgnoresBlankClipLink() async {
        let item = Fixtures.item(kind: .link, preview: "   ")
        let viewModel = await LauncherCommitRoutingFixtures.makeViewModel(rows: [.clip(item)])

        var opened = false
        viewModel.onOpenClipLink = { _ in opened = true }
        viewModel.perform(.openLink)

        #expect(!opened)
    }

    @Test func snippetRowRoutesPerModifier() async {
        let snippet = Snippet(title: "Standup", body: "Yesterday / Today")
        let viewModel = await LauncherCommitRoutingFixtures.makeViewModel(rows: [.snippet(snippet)])

        var pasted: [String] = []
        var copied: [String] = []
        viewModel.onPasteSnippet = { pasted.append($0.id) }
        viewModel.onCopySnippet = { copied.append($0.id) }

        viewModel.commit()
        viewModel.commit(modifier: .option) // same as ↩ for snippets
        viewModel.commit(modifier: .command)

        #expect(pasted == [snippet.id, snippet.id])
        #expect(copied == [snippet.id])
    }

    // MARK: - ⌘K palette

    @Test func paletteOpensFiltersAndRuns() async {
        let item = Fixtures.item(kind: .link, preview: "https://example.com")
        let viewModel = await LauncherCommitRoutingFixtures.makeViewModel(rows: [.clip(item)])

        // Opens only when a row with actions is selected.
        #expect(!viewModel.isPaletteOpen)
        viewModel.togglePalette()
        #expect(viewModel.isPaletteOpen)
        // Link clip actions: paste, copy, paste plain, open link.
        #expect(viewModel.filteredPaletteActions == [.paste, .copy, .pastePlain, .openLink, .preview, .pin])

        // Case-insensitive substring filter over the label.
        viewModel.paletteQuery = "LINK"
        #expect(viewModel.filteredPaletteActions == [.openLink])

        // Running the filtered action closes the palette and fires the effect.
        var opened: [URL] = []
        viewModel.onOpenClipLink = { opened.append($0) }
        viewModel.paletteIndex = 0
        viewModel.runPaletteAction()

        #expect(!viewModel.isPaletteOpen)
        #expect(opened == [URL(string: "https://example.com")])
    }

    @Test func paletteSelectionClampsToFilteredCount() async {
        let viewModel = await LauncherCommitRoutingFixtures.makeViewModel(rows: [.clip(Fixtures.item(preview: "x"))])
        viewModel.togglePalette()
        // Navigation clamps including the preview and pin actions.
        viewModel.movePaletteSelection(100)
        #expect(viewModel.paletteIndex == 4)
        viewModel.movePaletteSelection(-100)
        #expect(viewModel.paletteIndex == 0)
    }

    @Test func togglePaletteClosesWhenAlreadyOpen() async {
        let viewModel = await LauncherCommitRoutingFixtures.makeViewModel(rows: [.command(.version)])
        viewModel.togglePalette()
        #expect(viewModel.isPaletteOpen)
        viewModel.togglePalette()
        #expect(!viewModel.isPaletteOpen)
    }
}
