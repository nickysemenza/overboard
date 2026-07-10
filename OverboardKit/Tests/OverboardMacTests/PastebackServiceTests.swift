import AppKit
@testable import OverboardCore
@testable import OverboardMac
import Testing

/// Covers PastebackService's pasteboard construction — the UTI→type mapping,
/// file-URL fan-out, plain-text mode, and the paste-back marker — plus the
/// invariant that the marker it writes is one the monitor actually skips. These
/// build items in memory; they never touch the shared system pasteboard.
@MainActor
struct PastebackServiceTests {
    private func makeStore() throws -> ClipStore {
        let queue = try OverboardDatabase.openInMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-mac-\(UUID().uuidString)", isDirectory: true)
        let blobs = try BlobStore(directory: dir)
        return ClipStore(dbWriter: queue, blobs: blobs)
    }

    private func types(_ item: NSPasteboardItem) -> Set<NSPasteboard.PasteboardType> {
        Set(item.types)
    }

    // MARK: - UTI mapping

    @Test func pasteboardTypeMapping() {
        #expect(PastebackService.pasteboardType(for: WellKnownUTI.plainText) == .string)
        #expect(PastebackService.pasteboardType(for: WellKnownUTI.rtf) == .rtf)
        #expect(PastebackService.pasteboardType(for: WellKnownUTI.html) == .html)
        #expect(PastebackService.pasteboardType(for: WellKnownUTI.png) == .png)
        #expect(PastebackService.pasteboardType(for: WellKnownUTI.color)
            == NSPasteboard.PasteboardType(WellKnownUTI.color))
        #expect(PastebackService.pasteboardType(for: WellKnownUTI.fileURLs) == nil)
        #expect(PastebackService.pasteboardType(for: "public.unknown") == nil)
    }

    // MARK: - Build round-trips

    @Test func richTextCarriesAllFlavorsAndMarker() async throws {
        let store = try self.makeStore()
        let snapshot = PasteboardSnapshot(
            reps: [
                .init(uti: WellKnownUTI.plainText, data: Data("hello".utf8)),
                .init(uti: WellKnownUTI.rtf, data: Data("{\\rtf1 hello}".utf8)),
                .init(uti: WellKnownUTI.html, data: Data("<b>hello</b>".utf8)),
            ],
            sourceBundleID: "com.apple.TextEdit",
            sourceAppName: "TextEdit"
        )
        let item = try #require(await store.ingest(snapshot))
        let service = PastebackService(store: store)

        let pbItems = try await service.buildPasteboardItems(for: item, mode: .full)
        #expect(pbItems.count == 1)
        let flavors = self.types(pbItems[0])
        #expect(flavors.isSuperset(of: [.string, .rtf, .html]))
        #expect(flavors.contains(ClipboardMonitor.markerType))
    }

    @Test func plainTextModeDropsRichFlavors() async throws {
        let store = try self.makeStore()
        let snapshot = PasteboardSnapshot(
            reps: [
                .init(uti: WellKnownUTI.plainText, data: Data("hello".utf8)),
                .init(uti: WellKnownUTI.rtf, data: Data("{\\rtf1 hello}".utf8)),
                .init(uti: WellKnownUTI.html, data: Data("<b>hello</b>".utf8)),
            ],
            sourceBundleID: "com.apple.TextEdit",
            sourceAppName: "TextEdit"
        )
        let item = try #require(await store.ingest(snapshot))
        let service = PastebackService(store: store)

        let pbItems = try await service.buildPasteboardItems(for: item, mode: .plainText)
        let flavors = self.types(pbItems[0])
        #expect(flavors.contains(.string))
        #expect(flavors.contains(ClipboardMonitor.markerType))
        #expect(!flavors.contains(.rtf))
        #expect(!flavors.contains(.html))
    }

    @Test func fileURLsFanOutToOneItemEach() async throws {
        let store = try self.makeStore()
        let urls = ["/tmp/a.txt", "/tmp/b.txt"].map { URL(fileURLWithPath: $0).absoluteString }
        let snapshot = try PasteboardSnapshot(
            reps: [
                .init(uti: WellKnownUTI.fileURLs, data: JSONEncoder().encode(urls)),
                .init(uti: WellKnownUTI.plainText, data: Data("/tmp/a.txt\n/tmp/b.txt".utf8)),
            ],
            sourceBundleID: "com.apple.finder",
            sourceAppName: "Finder"
        )
        let item = try #require(await store.ingest(snapshot))
        let service = PastebackService(store: store)

        let pbItems = try await service.buildPasteboardItems(for: item, mode: .full)
        #expect(pbItems.count == 2) // one pasteboard item per file URL
        #expect(pbItems.allSatisfy { self.types($0).contains(.fileURL) })
        // The marker rides on the first item so the restore/copy isn't recaptured.
        #expect(self.types(pbItems[0]).contains(ClipboardMonitor.markerType))
    }

    // MARK: - Marker invariant

    @Test func markerWrittenIsOneTheMonitorSkips() async throws {
        // The exact-match invariant: PastebackService tags writes with
        // ClipboardMonitor.markerType, and the monitor's skip set contains it —
        // a mismatch would loop every paste-back back into history.
        #expect(ClipboardMonitor.skippedTypes.contains(ClipboardMonitor.markerType))

        let store = try self.makeStore()
        let item = try #require(await store.ingest(PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data("x".utf8))],
            sourceBundleID: nil,
            sourceAppName: nil
        )))
        let pbItems = try await PastebackService(store: store)
            .buildPasteboardItems(for: item, mode: .full)
        #expect(self.types(pbItems[0]).contains(ClipboardMonitor.markerType))
    }
}
