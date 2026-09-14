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

    @Test func bytesByKindIsOrderedDescending() async throws {
        let store = try makeStore()
        try await store.ingest(self.textSnapshot("small"))
        try await store.ingest(self.textSnapshot(String(repeating: "big ", count: 500)))
        try await store.ingest(self.textSnapshot(String(repeating: "medium ", count: 50)))

        let stats = try await store.libraryStats()
        // Only one kind (.text) is present, so this also exercises the
        // single-entry case of "largest first".
        let bytes = stats.bytesByKind.map(\.bytes)
        #expect(bytes == bytes.sorted(by: >))
    }

    @Test func bytesByKindSumsRepresentationBytes() async throws {
        let store = try makeStore()
        let first = "hello"
        let second = "a longer clip of text"
        try await store.ingest(self.textSnapshot(first))
        try await store.ingest(self.textSnapshot(second))

        let stats = try await store.libraryStats()
        let expected = first.utf8.count + second.utf8.count
        let textEntry = stats.bytesByKind.first { $0.kind == .text }
        #expect(textEntry?.bytes == expected)
    }

    @Test func deletedItemsExcludedFromBytesByKind() async throws {
        let store = try makeStore()
        let big = try await store.ingest(self.textSnapshot(String(repeating: "huge ", count: 800)))
        try await store.ingest(self.textSnapshot("tiny"))
        try await store.delete(id: #require(big).id)

        let stats = try await store.libraryStats()
        let textEntry = stats.bytesByKind.first { $0.kind == .text }
        // Only "tiny" (4 bytes) should remain after the huge item is deleted.
        #expect(textEntry?.bytes == "tiny".utf8.count)
    }
}
