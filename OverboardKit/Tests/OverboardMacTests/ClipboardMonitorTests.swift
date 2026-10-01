import AppKit
import OverboardCore
@testable import OverboardMac
import Testing

@MainActor
struct ClipboardMonitorTests {
    private func board() -> NSPasteboard {
        NSPasteboard(name: .init("overboard-monitor-tests-\(UUID().uuidString)"))
    }

    private func write(_ text: String, to board: NSPasteboard) {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    @Test func pendingCaptureCanBeFlushedBeforeInternalPublication() throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: board)
        self.write("pending", to: board)
        let snapshot = try #require(monitor.capturePendingSnapshot())
        #expect(snapshot.reps.first(where: { $0.uti == WellKnownUTI.plainText })?.data == Data("pending".utf8))
        #expect(monitor.capturePendingSnapshot() == nil)
        board.clearContents()
        let internalItem = NSPasteboardItem()
        internalItem.setString("internal", forType: .string)
        internalItem.setData(Data(), forType: ClipboardMonitor.markerType)
        board.writeObjects([internalItem])
        #expect(monitor.capturePendingSnapshot() == nil)
    }

    @Test func streamKeepsOnlyNewestBoundedSnapshots() async throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: board, bufferCapacity: 2)
        for text in ["first", "second", "third"] {
            self.write(text, to: board)
            #expect(monitor.flushPendingCapture())
        }
        var iterator = monitor.snapshots.makeAsyncIterator()
        let second = try #require(await iterator.next())
        let third = try #require(await iterator.next())
        #expect(second.reps.first(where: { $0.uti == WellKnownUTI.plainText })?.data == Data("second".utf8))
        #expect(third.reps.first(where: { $0.uti == WellKnownUTI.plainText })?.data == Data("third".utf8))
    }

    @Test(arguments: ["org.nspasteboard.SensitiveType", "com.apple.is-sensitive"])
    func sensitiveMarkerOnSecondaryItemSkipsBeforeReadingPayload(markerUTI: String) {
        let board = self.board()
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: board)
        let provider = MonitorReadProbe()
        let content = NSPasteboardItem()
        content.setDataProvider(provider, forTypes: [.string])
        let marker = NSPasteboardItem()
        marker.setData(Data(), forType: .init(markerUTI))
        board.clearContents()
        board.writeObjects([content, marker])
        #expect(monitor.capturePendingSnapshot() == nil)
        #expect(provider.readCount == 0)
    }

    @Test func aggregateByteLimitRejectsEntireSnapshot() {
        let board = self.board()
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(
            pasteboard: board, captureLimits: .init(maxSnapshotBytes: 8, maxRepresentationBytes: 8)
        )
        let items = [Data(repeating: 1, count: 5), Data(repeating: 2, count: 4)].map { data in
            let item = NSPasteboardItem()
            item.setData(data, forType: .html)
            return item
        }
        let provider = MonitorReadProbe()
        let unread = NSPasteboardItem()
        unread.setDataProvider(provider, forTypes: [.html])
        board.clearContents()
        #expect(board.writeObjects(items + [unread]))
        #expect(!monitor.flushPendingCapture())
        #expect(monitor.capturePendingSnapshot() == nil)
        #expect(provider.readCount == 0)
    }

    @Test func oversizedFlavorRejectsEntireSnapshot() {
        let board = self.board()
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(
            pasteboard: board, captureLimits: .init(maxSnapshotBytes: 16, maxRepresentationBytes: 4)
        )
        let item = NSPasteboardItem()
        item.setData(Data([1]), forType: .html)
        item.setData(Data(repeating: 2, count: 5), forType: .rtf)
        board.clearContents()
        #expect(board.writeObjects([item]))
        #expect(monitor.capturePendingSnapshot() == nil)
    }

    @Test func exactByteBudgetPreservesAllItemsAndFlavors() throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(
            pasteboard: board, captureLimits: .init(maxSnapshotBytes: 8, maxRepresentationBytes: 4)
        )
        let items = [Data(repeating: 1, count: 4), Data(repeating: 2, count: 4)].map { data in
            let item = NSPasteboardItem()
            item.setData(data, forType: .html)
            return item
        }
        board.clearContents()
        #expect(board.writeObjects(items))
        let snapshot = try #require(monitor.capturePendingSnapshot())
        #expect(snapshot.reps.map(\.itemIndex) == [0, 1])
        #expect(snapshot.reps.reduce(0) { $0 + $1.data.count } == 8)
    }

    @Test(arguments: ["items", "flavors", "representations"])
    func metadataLimitsRejectBeforeReadingPayload(limit: String) {
        let board = self.board()
        defer { board.releaseGlobally() }
        var limits = ClipboardMonitor.CaptureLimits()
        switch limit {
        case "items": limits.maxItemCount = 1
        case "flavors": limits.maxFlavorsPerItem = 1
        default: limits.maxRepresentationCount = 2
        }
        let monitor = ClipboardMonitor(pasteboard: board, captureLimits: limits)
        let provider = MonitorReadProbe()
        let items = (0 ..< 2).map { _ in
            let item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: [.html, .rtf])
            return item
        }
        board.clearContents()
        #expect(board.writeObjects(items))
        #expect(monitor.capturePendingSnapshot() == nil)
        #expect(provider.readCount == 0)
    }

    @Test func requestedLargeBufferRemainsCappedAtEight() async throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: board, bufferCapacity: 100)
        for index in 0 ..< 10 {
            self.write("\(index)", to: board)
            #expect(monitor.flushPendingCapture())
        }
        var iterator = monitor.snapshots.makeAsyncIterator()
        for index in 2 ..< 10 {
            let snapshot = try #require(await iterator.next())
            #expect(snapshot.reps.first(where: { $0.uti == WellKnownUTI.plainText })?.data == Data("\(index)".utf8))
        }
    }

    @Test func excludedApplicationSkipsBeforeReadingPayload() {
        let board = self.board()
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(
            pasteboard: board, sourceApplication: { ("com.example.password-manager", "Password Manager") }
        )
        monitor.excludedBundleIDs = { ["com.example.password-manager"] }
        let provider = MonitorReadProbe()
        let content = NSPasteboardItem()
        content.setDataProvider(provider, forTypes: [.string])
        board.clearContents()
        board.writeObjects([content])
        #expect(monitor.capturePendingSnapshot() == nil)
        #expect(provider.readCount == 0)
    }

    @Test func secureInputSkipsBeforeReadingPayload() {
        let board = self.board()
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: board, secureInputEnabled: { true })
        let provider = MonitorReadProbe()
        let content = NSPasteboardItem()
        content.setDataProvider(provider, forTypes: [.string])
        board.clearContents()
        board.writeObjects([content])
        #expect(monitor.capturePendingSnapshot() == nil)
        #expect(provider.readCount == 0)
    }

    @Test func richRepresentationsSurvivePendingCapture() throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: board)
        let item = NSPasteboardItem()
        item.setString("text", forType: .string)
        item.setData(Data("{\\rtf1 text}".utf8), forType: .rtf)
        item.setData(Data("<b>text</b>".utf8), forType: .html)
        board.clearContents()
        board.writeObjects([item])
        let snapshot = try #require(monitor.capturePendingSnapshot())
        #expect(Set(snapshot.reps.map(\.uti)).isSuperset(of: [
            WellKnownUTI.plainText, WellKnownUTI.rtf, WellKnownUTI.html,
        ]))
    }

    @Test func mixedItemsPreserveIdentityAndOriginalRichBytes() throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: board)
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
        board.clearContents()
        #expect(board.writeObjects(originals))
        let snapshot = try #require(monitor.capturePendingSnapshot())
        #expect(snapshot.reps.count == originals.reduce(0) { $0 + $1.types.count })
        for (index, original) in originals.enumerated() {
            for type in original.types {
                #expect(snapshot.reps.contains {
                    $0.itemIndex == index && $0.uti == type.rawValue && $0.data == original.data(forType: type)
                })
            }
        }
    }

    @Test func fileURLsKeepTheirItemAndCompanionFlavor() throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: board)
        let originals = ["file:///tmp/first.txt", "file:///tmp/second.txt"].map { url in
            let item = NSPasteboardItem()
            item.setString(url, forType: .fileURL)
            item.setString(url, forType: .string)
            return item
        }
        board.clearContents()
        #expect(board.writeObjects(originals))
        let snapshot = try #require(monitor.capturePendingSnapshot())
        for (index, original) in originals.enumerated() {
            let file = try #require(snapshot.reps.first { $0.itemIndex == index && $0.uti == WellKnownUTI.fileURLs })
            let url = try #require(original.string(forType: .fileURL))
            #expect(try JSONDecoder().decode([String].self, from: file.data) == [url])
            let text = try #require(snapshot.reps.first { $0.itemIndex == index && $0.uti == WellKnownUTI.plainText })
            #expect(text.data == original.data(forType: .string))
        }
    }
}

private final class MonitorReadProbe: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    var readCount: Int {
        self.lock.withLock { self.reads }
    }

    func pasteboard(
        _: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType
    ) {
        self.lock.withLock { self.reads += 1 }
        item.setString("private", forType: type)
    }
}
