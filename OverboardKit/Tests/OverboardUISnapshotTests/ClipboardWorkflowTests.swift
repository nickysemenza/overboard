import AppKit
import OverboardCore
@testable import OverboardMac
@testable import OverboardUI
import Testing

@Suite(.serialized)
@MainActor
struct ClipboardWorkflowTests {
    @Test(arguments: [PanelActionID.paste, .copy, .plainPaste])
    func captureSearchSelectAndDeliver(_ action: PanelActionID) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipStore(dbWriter: OverboardDatabase.openInMemory(), blobs: BlobStore(directory: directory))
        let board = NSPasteboard(name: .init("overboard-workflow-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: board, sourceApplication: { ("test.editor", "Test Editor") })
        defer { monitor.stop() }
        let originals = ["workflow first", "workflow second"].map { text in
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            item.setString("<b>\(text)</b>", forType: .html)
            return item
        }
        board.clearContents()
        #expect(board.writeObjects(originals))
        let captured = try #require(monitor.capturePendingSnapshot())
        let item = try #require(await store.ingest(captured))
        let model = DrawerViewModel(store: store, stack: PasteStack())
        defer { model.stopLiveUpdates() }
        model.applyBrowserState(.init(query: "workflow", selectedItemID: item.id, filter: .init()))
        await model.searchTask?.value
        #expect(model.selectedItem?.id == item.id)
        #expect(model.browserHandoff.query == "workflow")
        var dispatches = 0
        let service = PastebackService(store: store, pasteboard: board, isTrusted: { true },
                                       dispatch: { dispatches += 1; return true }, sleep: { _ in })
        service.beforePublication = {
            if let pending = monitor.capturePendingSnapshot() {
                _ = try await store.ingest(pending)
            }
        }
        board.clearContents()
        board.setString("pending external capture", forType: .string)
        var delivery: Task<PastebackService.Outcome, Never>?
        model.onCommit = { selected, mode in
            delivery = Task { await service.paste(selected, into: nil, restoreClipboard: false, mode: mode) }
        }
        model.onCopyClip = { selected in
            delivery = Task { await service.copy(selected) }
        }
        model.performPanelAction(action)
        let outcome = try await (#require(delivery)).value
        #expect(outcome == (action == .copy ? .copied : .dispatched))
        #expect(dispatches == (action == .copy ? 0 : 1))
        try self.assertPublishedPayload(on: board, for: action)
        #expect(monitor.capturePendingSnapshot() == nil)
        let history = try await store.recent(limit: 10)
        #expect(history.contains { $0.previewText == "pending external capture" })
        #expect(history.first(where: { $0.id == item.id })?.useCount == item.useCount + 1)
    }

    private func assertPublishedPayload(on board: NSPasteboard, for action: PanelActionID) throws {
        let published = try #require(board.pasteboardItems)
        #expect(published.map { $0.string(forType: .string) } == ["workflow first", "workflow second"])
        if action == .plainPaste {
            #expect(published.allSatisfy { !$0.types.contains(.html) && !$0.types.contains(.rtf) })
        } else {
            #expect(published.map { $0.string(forType: .html) } == [
                "<b>workflow first</b>", "<b>workflow second</b>",
            ])
        }
    }
}
