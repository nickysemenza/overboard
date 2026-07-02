import Foundation
import GRDB
@testable import OverboardCore
import Testing

struct FrecencyTests {
    /// Retains the queue so the test can seed rows with controlled timestamps
    /// and use-counts (the public API always stamps `lastUsedAt` to "now").
    private func makeStore() throws -> (ClipStore, DatabaseQueue) {
        let queue = try OverboardDatabase.openInMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-frecency-\(UUID().uuidString)", isDirectory: true)
        return try (ClipStore(dbWriter: queue, blobs: BlobStore(directory: dir)), queue)
    }

    private func seed(
        _ queue: DatabaseQueue,
        id: String,
        useCount: Int,
        ageHours: Double,
        pinned: Bool = false
    ) throws {
        let when = Date().addingTimeInterval(-ageHours * 3600)
        let item = ClipItem(
            id: id, contentHash: id, kind: .text, previewText: id,
            sourceBundleID: nil, sourceAppName: nil, byteSize: 1,
            isPinned: pinned, useCount: useCount,
            createdAt: when, lastUsedAt: when, updatedAt: when
        )
        try queue.write { db in try item.insert(db) }
    }

    @Test func frequentlyUsedItemOutranksSlightlyNewerRareOne() async throws {
        let (store, queue) = try makeStore()
        // "fresh" copied just now, used once. "frequent" copied 2h ago, used 8×.
        try seed(queue, id: "fresh", useCount: 1, ageHours: 0)
        try seed(queue, id: "frequent", useCount: 8, ageHours: 2)

        let ids = try await store.recent().map(\.id)
        #expect(ids.first == "frequent")
    }

    @Test func recencyStillDominatesOverStaleItems() async throws {
        let (store, queue) = try makeStore()
        // A once-used clip from now beats a once-used clip from days ago.
        try seed(queue, id: "recent", useCount: 1, ageHours: 0)
        try seed(queue, id: "stale", useCount: 1, ageHours: 240)

        let ids = try await store.recent().map(\.id)
        #expect(ids.first == "recent")
    }

    @Test func frequencyBonusSaturatesSoFreshCopiesArentBuried() async throws {
        let (store, queue) = try makeStore()
        // Even a very heavily reused but day-old item can't leapfrog a fresh
        // copy once the bonus caps (min(useCount, 8) → ~7.7h of lift max).
        try seed(queue, id: "fresh", useCount: 1, ageHours: 0)
        try seed(queue, id: "heavilyUsedButOld", useCount: 500, ageHours: 24)

        let ids = try await store.recent().map(\.id)
        #expect(ids.first == "fresh")
    }

    @Test func pinsAlwaysFloatAboveFrecency() async throws {
        let (store, queue) = try makeStore()
        try seed(queue, id: "freshUnpinned", useCount: 1, ageHours: 0)
        try seed(queue, id: "oldPinned", useCount: 1, ageHours: 100, pinned: true)

        let ids = try await store.recent().map(\.id)
        #expect(ids.first == "oldPinned")
    }
}
