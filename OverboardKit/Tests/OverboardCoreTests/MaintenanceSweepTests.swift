import Foundation
@testable import OverboardCore
import Testing

struct MaintenanceSweepTests {
    private func makeStore() throws -> (ClipStore, BlobStore) {
        let queue = try OverboardDatabase.openInMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-sweep-\(UUID().uuidString)", isDirectory: true)
        let blobs = try BlobStore(directory: dir)
        return try (ClipStore(dbWriter: queue, blobs: blobs), blobs)
    }

    /// A large image payload lands in the blob store, so ingest gives us a real
    /// referenced blob to protect.
    private func imageSnapshot(byteCount: Int) -> PasteboardSnapshot {
        PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.png, data: Data(repeating: 0xAB, count: byteCount))],
            sourceBundleID: "com.example.app",
            sourceAppName: "Example"
        )
    }

    @Test func deletesUnreferencedBlobButKeepsReferencedOnes() async throws {
        let (store, blobs) = try makeStore()
        // Referenced blob via a real ingested image (over the inline threshold).
        try await store.ingest(self.imageSnapshot(byteCount: Representation.inlineThreshold + 1))
        // A stray file no representation points at (simulates a crashed write).
        let orphanHash = try blobs.store(Data(repeating: 0x01, count: Representation.inlineThreshold + 1))

        let result = try await store.maintenanceSweep()

        #expect(result.orphanedBlobsDeleted == 1)
        #expect(result.missingBlobs == 0)
        #expect(!blobs.exists(hash: orphanHash))
        // The referenced blob survives — its item is still readable.
        let items = try await store.recent()
        let reps = try await store.representations(for: #require(items.first).id)
        #expect(try await store.payload(for: #require(reps.first)).count == Representation.inlineThreshold + 1)
    }

    @Test func reportsMissingBlobsWithoutThrowing() async throws {
        let (store, blobs) = try makeStore()
        let item = try await store.ingest(self.imageSnapshot(byteCount: Representation.inlineThreshold + 1))
        // Yank the backing file out from under the representation.
        let reps = try await store.representations(for: #require(item).id)
        let hash = try #require(reps.first { $0.blobHash != nil }?.blobHash)
        try blobs.delete(hash: hash)

        let result = try await store.maintenanceSweep()
        #expect(result.missingBlobs == 1)
        #expect(result.orphanedBlobsDeleted == 0)
    }

    @Test func isIdempotent() async throws {
        let (store, blobs) = try makeStore()
        _ = try blobs.store(Data(repeating: 0x02, count: Representation.inlineThreshold + 1))

        let first = try await store.maintenanceSweep()
        #expect(first.orphanedBlobsDeleted == 1)
        let second = try await store.maintenanceSweep()
        #expect(second == ClipStore.SweepResult(orphanedBlobsDeleted: 0, missingBlobs: 0))
    }
}
