import AppKit
import OverboardCore
@testable import OverboardMac
import Testing

extension PastebackSessionTests {
    @Test func mixedItemsRoundTripCaptureMaterializationAndPaste() async throws {
        let source = self.board()
        let destination = self.board()
        defer { source.releaseGlobally(); destination.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: source)
        let textItems = ["first", "second"].map { text in
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            item.setData(Data("<b>\(text)</b>".utf8), forType: .html)
            item.setData(Data("{\\rtf1 \(text)}".utf8), forType: .rtf)
            return item
        }
        let image = NSPasteboardItem()
        image.setData(Data([1, 2, 3]), forType: .png)
        image.setData(Data([4, 5, 6]), forType: .tiff)
        image.setData(Data([7, 8, 9]), forType: .init("com.example.rich"))
        let originals = textItems + [image]
        source.clearContents()
        #expect(source.writeObjects(originals))
        let snapshot = try #require(monitor.capturePendingSnapshot())
        let store = try self.makeStore()
        let clip = try #require(await store.ingest(snapshot))
        let service = PastebackService(
            store: store, pasteboard: destination, isTrusted: { true }, sleep: { _ in }
        )
        #expect(await service.paste(clip, into: nil, restoreClipboard: false) == .dispatched)
        let published = try #require(destination.pasteboardItems)
        #expect(published.count == originals.count)
        for index in originals.indices.reversed() {
            for type in originals[index].types {
                #expect(published[index].data(forType: type) == originals[index].data(forType: type))
            }
        }
    }

    @Test func indexedFileURLsKeepCompanionFlavorsAndMixedTextItem() async throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        let store = try self.makeStore()
        let snapshot = try PasteboardSnapshot(
            reps: [
                .init(uti: WellKnownUTI.plainText, data: Data("second".utf8), itemIndex: 1),
                .init(uti: WellKnownUTI.fileURLs, data: JSONEncoder().encode(["file:///tmp/first"]), itemIndex: 0),
                .init(uti: WellKnownUTI.plainText, data: Data("first file".utf8), itemIndex: 0),
                .init(uti: WellKnownUTI.html, data: Data("<b>first file</b>".utf8), itemIndex: 0),
            ], sourceBundleID: nil, sourceAppName: nil
        )
        let clip = try #require(await store.ingest(snapshot))
        let service = PastebackService(store: store, pasteboard: board)
        #expect(await service.copy(clip) == .copied)
        let items = try #require(board.pasteboardItems)
        #expect(items.count == 2)
        #expect(items[0].string(forType: .fileURL) == "file:///tmp/first")
        #expect(items[0].string(forType: .string) == "first file")
        #expect(items[0].data(forType: .html) == Data("<b>first file</b>".utf8))
        #expect(items[1].string(forType: .string) == "second")
        #expect(items[1].data(forType: .fileURL) == nil)
    }
}
