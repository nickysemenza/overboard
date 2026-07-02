import Foundation
@testable import OverboardCore
import Testing

struct StorageStatsTests {
    private func makeStore() throws -> ClipStore {
        let queue = try OverboardDatabase.openInMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-stats-\(UUID().uuidString)", isDirectory: true)
        return try ClipStore(dbWriter: queue, blobs: BlobStore(directory: dir))
    }

    private func textSnapshot(_ text: String) -> PasteboardSnapshot {
        PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data(text.utf8))],
            sourceBundleID: "com.example.app",
            sourceAppName: "Example"
        )
    }

    @Test func largestItemsAreOrderedBySizeDescending() async throws {
        let store = try makeStore()
        try await store.ingest(self.textSnapshot("small"))
        try await store.ingest(self.textSnapshot(String(repeating: "big ", count: 500)))
        try await store.ingest(self.textSnapshot(String(repeating: "medium ", count: 50)))

        let stats = try await store.libraryStats(topLargest: 5)
        #expect(stats.total == 3)
        #expect(stats.largest.count == 3)
        // Strictly descending by byte size.
        let sizes = stats.largest.map(\.byteSize)
        #expect(sizes == sizes.sorted(by: >))
        #expect(stats.largest.first?.byteSize == sizes.max())
    }

    @Test func largestRespectsLimit() async throws {
        let store = try makeStore()
        for index in 0 ..< 6 {
            try await store.ingest(self.textSnapshot("item \(index) \(String(repeating: "x", count: index * 10))"))
        }
        let stats = try await store.libraryStats(topLargest: 3)
        #expect(stats.largest.count == 3)
    }

    @Test func deletedItemsExcludedFromLargest() async throws {
        let store = try makeStore()
        let big = try await store.ingest(self.textSnapshot(String(repeating: "huge ", count: 800)))
        try await store.ingest(self.textSnapshot("tiny"))
        try await store.delete(id: #require(big).id)

        let stats = try await store.libraryStats()
        #expect(!stats.largest.contains { $0.id == big?.id })
    }
}
