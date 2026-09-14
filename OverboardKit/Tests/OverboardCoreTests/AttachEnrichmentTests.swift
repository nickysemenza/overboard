import Foundation
@testable import OverboardCore
import Testing

struct AttachEnrichmentTests {
    private func makeStore() throws -> ClipStore {
        let queue = try OverboardDatabase.openInMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-enrichment-\(UUID().uuidString)", isDirectory: true)
        return try ClipStore(dbWriter: queue, blobs: BlobStore(directory: dir))
    }

    private func pngSnapshot(_ data: Data) -> PasteboardSnapshot {
        PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.png, data: data)],
            sourceBundleID: "com.test",
            sourceAppName: "Test"
        )
    }

    /// Regression test for a bug the macOS 27 image-enrichment path exposed:
    /// `attachRecognizedText` sets `searchText = ""` (present, but never
    /// indexed into the external-content `item_fts` table) for a textless
    /// image, and `attachEnrichment` used to issue an FTS 'delete' for it
    /// unconditionally — which SQLite reports as "database disk image is
    /// malformed" for a rowid that was never inserted, rolling back the
    /// whole write and leaving the item unenriched. See the comment on the
    /// `if let oldSearchText, !oldSearchText.isEmpty` guard in
    /// `ClipStore+Enrichment.swift`.
    @Test func attachEnrichmentAfterEmptyRecognizedTextDoesNotCorruptTheIndex() async throws {
        let store = try self.makeStore()
        let item = try #require(try await store.ingest(self.pngSnapshot(Data(repeating: 0x7F, count: 64))))

        try await store.attachRecognizedText(itemID: item.id, text: "")
        try await store.attachEnrichment(itemID: item.id, title: "Blank Screenshot", category: "other")

        let items = try await store.recent(limit: 10)
        let reloaded = try #require(items.first { $0.id == item.id })
        #expect(reloaded.aiTitle == "Blank Screenshot")
        #expect(reloaded.category == "other")
        #expect(try await store.search("blank").count == 1)
    }
}
