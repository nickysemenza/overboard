import Foundation
import GRDB
@testable import OverboardCore
import Testing

struct SecretRetentionTests {
    private func makeStore() throws -> ClipStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("secret-retention-\(UUID().uuidString)")
        return try ClipStore(dbWriter: OverboardDatabase.openInMemory(), blobs: BlobStore(directory: directory))
    }

    private func snapshot(_ text: String, at date: Date = Date()) -> PasteboardSnapshot {
        PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data(text.utf8))],
            sourceBundleID: nil, sourceAppName: nil, capturedAt: date
        )
    }

    @Test func ageAndCountCleanupPreservesSecretsAfterUnpinning() async throws {
        let store = try self.makeStore()
        let old = Date(timeIntervalSince1970: 0)
        let secret = try #require(await store.ingest(self.snapshot("AKIAIOSFODNN7EXAMPLE", at: old)))
        try await store.setPinned(id: secret.id, true)
        try await store.setPinned(id: secret.id, false)
        try await store.ingest(self.snapshot("ordinary old clip", at: old))
        try await store.ingest(self.snapshot("ordinary newest clip"))
        try await store.purge(keepingLatest: 1, olderThan: Date().addingTimeInterval(-60))
        let remaining = try await store.recent()
        #expect(remaining.count == 2)
        #expect(remaining.contains { $0.id == secret.id })
        #expect(try await store.plainText(for: secret.id) == "AKIAIOSFODNN7EXAMPLE")
        try await store.purge(keepingLatest: 0)
        #expect(try await store.recent().map(\.id) == [secret.id])
    }

    @Test func OCRSecretReclassificationRemovesEarlierIndexesAndMetadata() async throws {
        let database = try OverboardDatabase.openInMemory()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("secret-ocr-\(UUID().uuidString)")
        let store = try ClipStore(dbWriter: database, blobs: BlobStore(directory: directory))
        let snapshot = PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.png, data: Data([1, 2, 3]))],
            sourceBundleID: nil, sourceAppName: nil
        )
        let item = try #require(await store.ingest(snapshot))
        try await store.attachRecognizedText(itemID: item.id, text: "ordinary invoice")
        try await store.attachEnrichment(itemID: item.id, title: "Searchable Invoice", category: "finance")
        try await database.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO item_embedding (itemID, vector) VALUES (?, ?)",
                arguments: [item.id, Data([1, 2, 3])]
            )
        }
        #expect(try await store.search("invoice").count == 1)
        let safe = try await store.attachRecognizedText(itemID: item.id, text: "credential AKIAIOSFODNN7EXAMPLE")
        #expect(!safe)
        let protected = try #require(await store.recent().first)
        #expect(protected.isSecret)
        #expect(protected.previewText == "Secret — AWS access key")
        #expect(protected.aiTitle == nil)
        #expect(protected.sourceURL == nil)
        #expect(try await store.search("invoice").isEmpty)
        #expect(try await store.search("AKIA").isEmpty)
        let embeddings = try await database.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item_embedding WHERE itemID = ?", arguments: [item.id])
        }
        #expect(embeddings == 0)
        try await store.attachEnrichment(itemID: item.id, title: "Leaked", category: "other")
        #expect(try await store.recent().first?.aiTitle == nil)
        let payload = try await store.materialize(itemIDs: [item.id]).first?.representations.first?.payload
        #expect(payload == Data([1, 2, 3]))
    }

    @Test func secretBeyondIndexLimitIsDetectedBeforeTruncation() async throws {
        let store = try self.makeStore()
        let body = String(repeating: "ordinary text ", count: 2000) + "AKIAIOSFODNN7EXAMPLE"
        let item = try #require(await store.ingest(self.snapshot(body)))
        #expect(item.isSecret)
        #expect(try await store.search("ordinary").isEmpty)
        #expect(try await store.plainText(for: item.id) == body)
    }

    @Test func OCRSecretPreventsBothTextAndImageLabeling() async throws {
        let store = try self.makeStore()
        let snapshot = PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.png, data: Data([4, 5, 6]))],
            sourceBundleID: nil, sourceAppName: nil
        )
        let item = try #require(await store.ingest(snapshot))
        let pipeline = ClipEnrichmentPipeline(
            store: store,
            recognizeText: { _ in "AKIAIOSFODNN7EXAMPLE" },
            enrichText: { _ in Issue.record("Secret text reached labeling"); return nil },
            enrichImage: { _, _ in Issue.record("Secret pixels reached labeling"); return nil }
        )
        await pipeline.enrich(item: item, snapshot: snapshot)
        #expect(try await store.recent().first?.isSecret == true)
    }

    @Test func legacyRemoteSettingsCannotEnableFetching() {
        var settings = EnrichmentSettings(richLinkPreviews: true)
        #expect(!settings.richLinkPreviews)
        settings.richLinkPreviews = true
        #expect(!settings.richLinkPreviews)
        #expect(settings.ocrEnabled)
        #expect(settings.labelingEnabled)
    }
}
