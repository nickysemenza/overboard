import Foundation
@testable import OverboardCore
import Testing

struct ClipboardBrowserTests {
    /// Ingests a plain-text clip, split out of the big test below to keep its
    /// body within the function-length limit.
    private func ingestText(
        _ text: String, sourceBundleID: String?, sourceAppName: String?, in store: ClipStore
    ) async throws -> ClipItem {
        try #require(await store.ingest(PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data(text.utf8))],
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName
        )))
    }

    @Test func filtersBeforeLimitingAndPreservesOCRSearch() async throws {
        let database = try OverboardDatabase.openInMemory()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try ClipStore(dbWriter: database, blobs: BlobStore(directory: directory))
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await self.ingestText(
            "meeting notes", sourceBundleID: "notes", sourceAppName: "Notes", in: store
        )
        _ = try await self.ingestText(
            "meeting agenda", sourceBundleID: "browser", sourceAppName: "Browser", in: store
        )
        try await store.setPinned(id: first.id, true)
        let pngBase64 = """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6\
        kgAAAABJRU5ErkJggg==
        """
        let png = try #require(Data(base64Encoded: pngBase64))
        let image = try #require(await store.ingest(PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.png, data: png)],
            sourceBundleID: "notes",
            sourceAppName: "Notes"
        )))
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
        _ = try await self.ingestText("continue with cat", sourceBundleID: nil, sourceAppName: nil, in: store)
        #expect(try await store.search("c++").isEmpty)
        let cpp = try await self.ingestText("a c++ tutorial", sourceBundleID: nil, sourceAppName: nil, in: store)
        #expect(try await store.search("c++").map(\.id) == [cpp.id])
        #expect(try await store.browseHistory("c++").map(\.id) == [cpp.id])
        try await store.delete(id: image.id)
        #expect(try await store.browseHistory("unique").isEmpty)
    }
}
