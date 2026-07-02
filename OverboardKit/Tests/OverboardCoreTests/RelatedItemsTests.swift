import Foundation
import GRDB
@testable import OverboardCore
import Testing

/// Deterministic tests for `ClipStore.relatedItems`. Vectors are inserted
/// directly into `item_embedding` so the tests don't depend on the NLEmbedding
/// model (which isn't available in CI and isn't deterministic across OS
/// versions).
struct RelatedItemsTests {
    /// A queue plus a store sharing it, so tests can seed rows directly and
    /// query through the public API.
    private func makeStoreAndQueue() throws -> (ClipStore, DatabaseQueue) {
        let queue = try OverboardDatabase.openInMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-related-\(UUID().uuidString)", isDirectory: true)
        let store = try ClipStore(dbWriter: queue, blobs: BlobStore(directory: dir))
        return (store, queue)
    }

    /// Insert a bare item row plus (optionally) an embedding vector.
    private func seed(
        _ queue: DatabaseQueue,
        id: String,
        contentHash: String? = nil,
        previewText: String = "text",
        isSecret: Bool = false,
        deleted: Bool = false,
        vector: [Double]? = nil
    ) throws {
        let now = Date()
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO item
                  (id, contentHash, kind, previewText, byteSize, isSecret,
                   useCount, createdAt, lastUsedAt, updatedAt, deletedAt)
                VALUES (?, ?, 'text', ?, 1, ?, 1, ?, ?, ?, ?)
                """,
                arguments: [
                    id, contentHash ?? id, previewText, isSecret,
                    now, now, now, deleted ? now : nil,
                ]
            )
            if let vector {
                try db.execute(
                    sql: "INSERT INTO item_embedding (itemID, vector) VALUES (?, ?)",
                    arguments: [id, EmbeddingCoder.encode(vector)]
                )
            }
        }
    }

    @Test func ordersBySimilarityDescending() async throws {
        let (store, queue) = try makeStoreAndQueue()
        try self.seed(queue, id: "target", vector: [1, 0, 0])
        try self.seed(queue, id: "near", vector: [0.9, 0.1, 0]) // most similar
        try self.seed(queue, id: "mid", vector: [0.7, 0.7, 0])
        try self.seed(queue, id: "far", vector: [0.6, 0.6, 0.5])

        let related = try await store.relatedItems(to: "target", limit: 5, minSimilarity: 0.0)
        #expect(related.map(\.id) == ["near", "mid", "far"])
    }

    @Test func respectsLimit() async throws {
        let (store, queue) = try makeStoreAndQueue()
        try self.seed(queue, id: "target", vector: [1, 0, 0])
        for index in 0 ..< 6 {
            try self.seed(queue, id: "n\(index)", vector: [1, Double(index) * 0.05, 0])
        }

        let related = try await store.relatedItems(to: "target", limit: 3, minSimilarity: 0.0)
        #expect(related.count == 3)
    }

    @Test func filtersBelowThreshold() async throws {
        let (store, queue) = try makeStoreAndQueue()
        try self.seed(queue, id: "target", vector: [1, 0, 0])
        try self.seed(queue, id: "close", vector: [0.95, 0.05, 0]) // ~0.998
        try self.seed(queue, id: "orthogonal", vector: [0, 1, 0]) // 0.0

        let related = try await store.relatedItems(to: "target", limit: 5, minSimilarity: 0.8)
        #expect(related.map(\.id) == ["close"])
    }

    @Test func excludesSelf() async throws {
        let (store, queue) = try makeStoreAndQueue()
        try self.seed(queue, id: "target", vector: [1, 0, 0])
        try self.seed(queue, id: "other", vector: [1, 0, 0])

        let related = try await store.relatedItems(to: "target", limit: 5, minSimilarity: 0.0)
        #expect(related.map(\.id) == ["other"])
    }

    @Test func excludesSameContentHash() async throws {
        let (store, queue) = try makeStoreAndQueue()
        try self.seed(queue, id: "target", contentHash: "shared", vector: [1, 0, 0])
        // A duplicate (same content) under a different id. The live-uniqueness
        // index on contentHash means a duplicate can only coexist as a
        // soft-deleted row, so this exercises the contentHash filter for a row
        // that would otherwise slip past a naive deletedAt-only check.
        try self.seed(queue, id: "dupe", contentHash: "shared", deleted: true, vector: [1, 0, 0])
        try self.seed(queue, id: "distinct", contentHash: "other", vector: [0.9, 0.1, 0])

        let related = try await store.relatedItems(to: "target", limit: 5, minSimilarity: 0.0)
        #expect(related.map(\.id) == ["distinct"])
    }

    @Test func excludesSecrets() async throws {
        let (store, queue) = try makeStoreAndQueue()
        try self.seed(queue, id: "target", vector: [1, 0, 0])
        try self.seed(queue, id: "secret", isSecret: true, vector: [1, 0, 0])
        try self.seed(queue, id: "visible", vector: [0.9, 0.1, 0])

        let related = try await store.relatedItems(to: "target", limit: 5, minSimilarity: 0.0)
        #expect(related.map(\.id) == ["visible"])
    }

    @Test func excludesDeletedNeighbours() async throws {
        let (store, queue) = try makeStoreAndQueue()
        try self.seed(queue, id: "target", vector: [1, 0, 0])
        try self.seed(queue, id: "gone", deleted: true, vector: [1, 0, 0])
        try self.seed(queue, id: "alive", vector: [0.9, 0.1, 0])

        let related = try await store.relatedItems(to: "target", limit: 5, minSimilarity: 0.0)
        #expect(related.map(\.id) == ["alive"])
    }

    @Test func returnsEmptyWhenTargetHasNoEmbedding() async throws {
        let (store, queue) = try makeStoreAndQueue()
        try self.seed(queue, id: "target", vector: nil) // no embedding
        try self.seed(queue, id: "other", vector: [1, 0, 0])

        let related = try await store.relatedItems(to: "target", limit: 5, minSimilarity: 0.0)
        #expect(related.isEmpty)
    }
}
