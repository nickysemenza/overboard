import Foundation
import GRDB
@testable import OverboardCore
import Testing

private actor EnrichmentGate<Value: Sendable> {
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var resultWaiter: CheckedContinuation<Value, Never>?

    func suspend() async -> Value {
        self.started = true
        self.startedWaiter?.resume()
        self.startedWaiter = nil
        return await withCheckedContinuation { self.resultWaiter = $0 }
    }

    func waitUntilStarted() async {
        if self.started {
            return
        }
        await withCheckedContinuation { self.startedWaiter = $0 }
    }

    func resume(returning value: Value) {
        self.resultWaiter?.resume(returning: value)
        self.resultWaiter = nil
    }
}

struct EnrichmentCancellationTests {
    private func makeStore() throws -> (store: ClipStore, database: DatabaseQueue) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("enrichment-cancellation-\(UUID().uuidString)")
        let database = try OverboardDatabase.openInMemory()
        return try (ClipStore(dbWriter: database, blobs: BlobStore(directory: directory)), database)
    }

    @Test func cancelledBlockedRecognizerCannotPublishOrReclassify() async throws {
        let (store, database) = try self.makeStore()
        let snapshot = PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.png, data: Data([1, 2, 3]))],
            sourceBundleID: nil, sourceAppName: nil
        )
        let item = try #require(await store.ingest(snapshot))
        let gate = EnrichmentGate<String?>()
        let pipeline = ClipEnrichmentPipeline(
            store: store,
            recognizeText: { _ in await gate.suspend() },
            enrichText: { _ in Issue.record("Cancelled OCR reached text labeling"); return nil },
            enrichImage: { _, _ in Issue.record("Cancelled OCR reached image labeling"); return nil }
        )
        let task = Task { await pipeline.enrich(item: item, snapshot: snapshot) }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.resume(returning: "AKIAIOSFODNN7EXAMPLE")
        await task.value
        let stored = try #require(await store.recent().first)
        #expect(!stored.isSecret)
        #expect(stored.aiTitle == nil)
        let searchText = try await database.read {
            try String.fetchOne($0, sql: "SELECT searchText FROM item WHERE id = ?", arguments: [item.id])
        }
        #expect(searchText == nil)
    }

    @Test func cancelledBlockedTextEnricherCannotPublish() async throws {
        let (store, _) = try self.makeStore()
        let snapshot = PasteboardSnapshot(
            reps: [
                .init(uti: WellKnownUTI.plainText, data: Data(String(repeating: "ordinary prose ", count: 10).utf8)),
            ],
            sourceBundleID: nil, sourceAppName: nil
        )
        let item = try #require(await store.ingest(snapshot))
        let gate = EnrichmentGate<ClipEnricher.Enrichment?>()
        let pipeline = ClipEnrichmentPipeline(store: store, enrichText: { _ in await gate.suspend() })
        let task = Task { await pipeline.enrich(item: item, snapshot: snapshot) }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.resume(returning: .init(title: "Late result", category: "other", summary: "Late summary"))
        await task.value
        #expect(try await store.recent().first?.aiTitle == nil)
    }

    @Test func cancelledDirectStoreAttachmentsRejectPublication() async throws {
        let (store, _) = try self.makeStore()
        let item = try #require(await store.ingest(PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.png, data: Data([1, 2, 3]))],
            sourceBundleID: nil, sourceAppName: nil
        )))
        let gate = EnrichmentGate<Void>()
        let task = Task {
            await gate.suspend()
            try await store.attachRecognizedText(itemID: item.id, text: "AKIAIOSFODNN7EXAMPLE")
        }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.resume(returning: ())
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.recent().first?.isSecret == false)
    }

    @Test func cancelledBlockedImageEnricherCannotPublish() async throws {
        let (store, _) = try self.makeStore()
        let snapshot = PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.png, data: Data([1, 2, 3]))],
            sourceBundleID: nil, sourceAppName: nil
        )
        let item = try #require(await store.ingest(snapshot))
        let gate = EnrichmentGate<ClipEnricher.Enrichment?>()
        let pipeline = ClipEnrichmentPipeline(
            store: store, recognizeText: { _ in "" },
            enrichImage: { _, _ in await gate.suspend() }
        )
        let task = Task { await pipeline.enrich(item: item, snapshot: snapshot) }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.resume(returning: .init(title: "Late image", category: "other", summary: "Late summary"))
        await task.value
        #expect(try await store.recent().first?.aiTitle == nil)
    }
}
