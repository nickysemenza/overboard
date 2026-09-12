import Foundation
@testable import OverboardCore
import Testing

struct ClipboardBrowserTests {
    @Test func filtersBeforeLimitingAndPreservesOCRSearch() async throws {
        let database = try OverboardDatabase.openInMemory()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try ClipStore(dbWriter: database, blobs: BlobStore(directory: directory))
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try #require(await store.ingest(PasteboardSnapshot(reps: [.init(uti: WellKnownUTI.plainText, data: Data("meeting notes".utf8))], sourceBundleID: "notes", sourceAppName: "Notes")))
        _ = try await store.ingest(PasteboardSnapshot(reps: [.init(uti: WellKnownUTI.plainText, data: Data("meeting agenda".utf8))], sourceBundleID: "browser", sourceAppName: "Browser"))
        try await store.setPinned(id: first.id, true)
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
        let image = try #require(await store.ingest(PasteboardSnapshot(reps: [.init(uti: WellKnownUTI.png, data: png)], sourceBundleID: "notes", sourceAppName: "Notes")))
        try await store.setPinned(id: image.id, true)
        try await store.attachRecognizedText(itemID: image.id, text: "unique OCR words")
        var filter = ClipboardFilter()
        filter.source = "Notes"
        filter.pinnedOnly = true
        filter.period = .today
        #expect(try await store.browseHistory("meeting", filter: filter, limit: 1).map(\.id) == [first.id])
        #expect(try await store.browseHistory("unique", filter: filter).map(\.id) == [image.id])
        filter.kind = .image
        #expect(try await store.browseHistory("", filter: filter).map(\.id) == [image.id])
        #expect(try await store.browseHistory("---").isEmpty)
        _ = try await store.ingest(PasteboardSnapshot(reps: [.init(uti: WellKnownUTI.plainText, data: Data("continue with cat".utf8))], sourceBundleID: nil, sourceAppName: nil))
        #expect(try await store.search("c++").isEmpty)
        let cpp = try #require(await store.ingest(PasteboardSnapshot(reps: [.init(uti: WellKnownUTI.plainText, data: Data("a c++ tutorial".utf8))], sourceBundleID: nil, sourceAppName: nil)))
        #expect(try await store.search("c++").map(\.id) == [cpp.id])
        #expect(try await store.browseHistory("c++").map(\.id) == [cpp.id])
        try await store.delete(id: image.id)
        #expect(try await store.browseHistory("unique").isEmpty)
    }
}
