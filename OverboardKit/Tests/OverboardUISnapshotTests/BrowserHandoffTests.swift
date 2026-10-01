import OverboardCore
@testable import OverboardUI
import Testing

@Suite(.serialized)
@MainActor
struct BrowserHandoffTests {
    @Test func launcherRestoresItemIdentityRatherThanRowIndex() async {
        let first = Fixtures.item(preview: "first clipboard")
        let second = Fixtures.item(preview: "second clipboard")
        let model = await LauncherCommitRoutingFixtures.makeViewModel(rows: [.clip(first), .clip(second)])
        model.restoreBrowserSelection(itemID: second.id)
        #expect(model.browserHandoff.selectedItemID == second.id)
        #expect(model.browserHandoff.query == "zzz")
        model.restoreBrowserSelection(itemID: "removed-item")
        #expect(model.browserHandoff.selectedItemID == second.id)
    }

    @Test func drawerAppliesQueryFilterAndPendingSelectedIDOnPublication() async throws {
        let store = try Fixtures.store()
        _ = try await store.ingest(Fixtures.textSnapshot("one handoff"))
        _ = try await store.ingest(Fixtures.textSnapshot("two handoff"))
        let items = try await store.recent(limit: 10)
        let selected = try #require(items.first(where: { $0.previewText == "one handoff" }))
        var filter = ClipboardFilter()
        filter.kind = .text
        let state = ClipboardBrowserHandoff(query: "handoff", selectedItemID: selected.id, filter: filter)
        let model = DrawerViewModel(store: store, stack: PasteStack())
        model.applyBrowserState(state)
        await model.searchTask?.value
        #expect(model.browserHandoff == state)
        model.toggleMode()
        await model.searchTask?.value
        #expect(model.browserFilter == ClipboardFilter())
    }
}
