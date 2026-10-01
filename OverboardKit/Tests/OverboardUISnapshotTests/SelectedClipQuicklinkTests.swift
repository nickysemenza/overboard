import Defaults
import OverboardCore
import OverboardMac
@testable import OverboardUI
import Testing

@Suite(.serialized)
@MainActor
struct SelectedClipQuicklinkTests {
    @Test func launcherDispatchesSelectedItemAndUntouchedTemplate() async {
        let original = Defaults[.launcherQuicklinks]
        defer { Defaults[.launcherQuicklinks] = original }
        Defaults[.launcherQuicklinks] = "lookup = Search Example | https://example.com/?q={clipboard}"
        let item = Fixtures.item(preview: "preview is not the full payload")
        let model = await LauncherCommitRoutingFixtures.makeViewModel(rows: [.clip(item)])
        model.paletteQuery = "selected clipboard"
        #expect(model.filteredPaletteEntries(includeStack: false).isEmpty)
        let entries = model.filteredPaletteEntries(includeStack: false, includeClipQuicklinks: true)
        #expect(entries.count == 1)
        #expect(entries.first?.id == "clipboardQuicklink:lookup")
        #expect(entries.first?.detail == "https://example.com/?q={clipboard}")
        var received: (String, String)?
        model.runPaletteEntry(onRunClipQuicklink: { selected, quicklink in
            received = (selected.id, quicklink.template)
        })
        #expect(received?.0 == item.id)
        #expect(received?.1 == "https://example.com/?q={clipboard}")
    }

    @Test func drawerDispatchMatchesFilteredEntryAndRequiresIntegration() throws {
        let original = Defaults[.launcherQuicklinks]
        defer { Defaults[.launcherQuicklinks] = original }
        Defaults[.launcherQuicklinks] = "lookup = Search Example | https://example.com/?q={query}"
        let model = try DrawerViewModel(store: Fixtures.store(), stack: PasteStack())
        let item = Fixtures.item(preview: "selected history item")
        model.items = [item]
        model.paletteQuery = "selected clipboard"
        #expect(model.filteredPaletteActions.isEmpty)
        var received: (String, String)?
        model.onRunClipQuicklink = { selected, quicklink in received = (selected.id, quicklink.template) }
        #expect(model.filteredPaletteActions.map(\.id) == ["clipboardQuicklink:lookup"])
        model.runPaletteAction()
        #expect(received?.0 == item.id)
        #expect(received?.1 == "https://example.com/?q={query}")
    }

    @Test func invalidDestinationsAndNonTextSelectionsAreExcluded() {
        let original = Defaults[.launcherQuicklinks]
        defer { Defaults[.launcherQuicklinks] = original }
        Defaults[.launcherQuicklinks] = """
        good = https://example.com/?q={clipboard}
        bad = javascript:alert(1)
        unknown = https://example.com/{secret}
        bad keyword = https://example.com/
        """
        #expect(SelectedClipQuicklinks.available(for: Fixtures.item(preview: "text")).map(\.keyword) == ["good"])
        var secretItem = Fixtures.item(preview: "detected secret")
        secretItem.isSecret = true
        #expect(SelectedClipQuicklinks.available(for: secretItem).isEmpty)
        secretItem.kind = .link
        #expect(SelectedClipQuicklinks.available(for: secretItem).isEmpty)
        #expect(SelectedClipQuicklinks.available(for: Fixtures.item(kind: .image, preview: "image")).isEmpty)
        #expect(SelectedClipQuicklinks.available(for: nil).isEmpty)
    }
}
