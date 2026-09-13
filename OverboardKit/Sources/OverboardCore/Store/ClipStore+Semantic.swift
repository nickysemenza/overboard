import Foundation
import GRDB

// MARK: - Semantic search

public extension ClipStore {
    internal func storeEmbedding(itemID: String, text: String) async throws {
        guard let embedding = sentenceEmbedding,
              let vector = embedding.vector(for: String(text.prefix(300)))
        else { return }
        let blob = EmbeddingCoder.encode(vector)
        try await self.dbWriter.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO item_embedding (itemID, vector) VALUES (?, ?)",
                arguments: [itemID, blob]
            )
        }
    }

    /// On-device semantic search over text/link items: cosine similarity of
    /// NLEmbedding sentence vectors. Complements FTS — finds "that key from
    /// AWS" when the words don't literally match.
    func semanticSearch(
        _ query: String,
        limit: Int = 10,
        minSimilarity: Double = 0.75
    ) async throws -> [ClipItem] {
        guard let embedding = sentenceEmbedding,
              let queryVector = embedding.vector(for: query)
        else { return [] }

        // Capped to the 1000 most recently used items rather than scoring the
        // whole embedding table in Swift: recent items are what people
        // actually search for, and the cap bounds memory at ~3 MB (1000 ×
        // ~768 dims × 4 bytes) regardless of how large history grows.
        // GRDB `Row`s are not `Sendable`, so they are projected onto plain
        // values inside the closure rather than handed back across it.
        let rows: [(id: String, vector: Data)] = try await self.dbWriter.read { db in
            try Row.fetchAll(db, sql: """
            SELECT e.itemID, e.vector
            FROM item_embedding e
            JOIN item i ON i.id = e.itemID
            WHERE i.deletedAt IS NULL
            ORDER BY i.lastUsedAt DESC
            LIMIT 1000
            """).map { (id: $0["itemID"] as String, vector: $0["vector"] as Data) }
        }

        let query32 = queryVector.map(Float.init)
        let scored: [(id: String, score: Float)] = rows.compactMap { row in
            let vector = EmbeddingCoder.decode(row.vector)
            guard !vector.isEmpty else { return nil }
            let score = EmbeddingCoder.cosineSimilarity(query32, vector)
            return score >= Float(minSimilarity) ? (row.id, score) : nil
        }

        let topIDs = scored.sorted { $0.score > $1.score }.prefix(limit).map(\.id)
        guard !topIDs.isEmpty else { return [] }

        let items = try await self.dbWriter.read { db in
            try ClipItem
                .filter(sql: "deletedAt IS NULL")
                .filter(keys: topIDs)
                .fetchAll(db)
        }
        // Preserve similarity order.
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return topIDs.compactMap { byID[$0] }
    }

    // MARK: - Related

    /// K-nearest neighbours to a given item by cosine similarity of their
    /// stored embedding vectors. Excludes the item itself, other copies of
    /// the same content, secrets, and deleted items. Returns `[]` when the
    /// target has no embedding.
    func relatedItems(
        to itemID: String,
        limit: Int = 5,
        minSimilarity: Double = 0.8
    ) async throws -> [ClipItem] {
        let (target, neighbours): ([Float], [(id: String, vector: Data)]) = try await self.dbWriter.read { db in
            guard let targetRow = try Row.fetchOne(db, sql: """
            SELECT i.contentHash AS contentHash, e.vector AS vector
            FROM item_embedding e
            JOIN item i ON i.id = e.itemID
            WHERE e.itemID = ?
            """, arguments: [itemID])
            else { return ([], []) }

            let targetVector = EmbeddingCoder.decode(targetRow["vector"] as Data)
            guard !targetVector.isEmpty else { return ([], []) }
            let targetHash = targetRow["contentHash"] as String

            // Same 1000-item recency cap as `semanticSearch` — see its comment.
            let rows = try Row.fetchAll(db, sql: """
            SELECT e.itemID AS itemID, e.vector AS vector
            FROM item_embedding e
            JOIN item i ON i.id = e.itemID
            WHERE i.deletedAt IS NULL
              AND i.isSecret = 0
              AND e.itemID != ?
              AND i.contentHash != ?
            ORDER BY i.lastUsedAt DESC
            LIMIT 1000
            """, arguments: [itemID, targetHash])

            let vectors = rows.map { (id: $0["itemID"] as String, vector: $0["vector"] as Data) }
            return (targetVector, vectors)
        }

        guard !target.isEmpty else { return [] }

        let scored: [(id: String, score: Float)] = neighbours.compactMap { neighbour in
            let vector = EmbeddingCoder.decode(neighbour.vector)
            guard !vector.isEmpty else { return nil }
            let score = EmbeddingCoder.cosineSimilarity(target, vector)
            return score >= Float(minSimilarity) ? (neighbour.id, score) : nil
        }

        let topIDs = scored.sorted { $0.score > $1.score }.prefix(limit).map(\.id)
        guard !topIDs.isEmpty else { return [] }

        let items = try await self.dbWriter.read { db in
            try ClipItem
                .filter(sql: "deletedAt IS NULL")
                .filter(keys: topIDs)
                .fetchAll(db)
        }
        // Preserve similarity order.
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return topIDs.compactMap { byID[$0] }
    }
}
