import Foundation
import GRDB
@testable import OverboardCore
import os
import Testing

/// Pins the capture-cost restructuring: a recopy of live content is detected
/// right after the content hash and skips provenance, sensitivity scanning,
/// blob storage, embedding, and enrichment, while still bumping the row.
struct IngestFastPathTests {
    private struct Harness {
        let store: ClipStore
        let blobs: BlobStore
        let dbWriter: any DatabaseWriter

        init() throws {
            let queue = try OverboardDatabase.openInMemory()
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("overboard-fastpath-\(UUID().uuidString)", isDirectory: true)
            self.blobs = try BlobStore(directory: dir)
            self.dbWriter = queue
            self.store = ClipStore(dbWriter: queue, blobs: self.blobs)
        }
    }

    private func textSnapshot(_ text: String) -> PasteboardSnapshot {
        PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data(text.utf8))],
            sourceBundleID: nil, sourceAppName: nil
        )
    }

    /// Counts provenance lookups; the closure is what the real app wires to an
    /// AppleScript round trip.
    private func countingResolver(_ counter: OSAllocatedUnfairLock<Int>) -> ProvenanceResolver {
        {
            counter.withLock { $0 += 1 }
            return ("https://example.com/page", "Page")
        }
    }

    @Test func recopyBumpsUseCountWithoutProvenanceOrBlobWork() async throws {
        let harness = try Harness()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        // Over the inline threshold so the payload lands in the blob store.
        let big = String(repeating: "recopy payload ", count: Representation.inlineThreshold / 8)

        let first = try #require(try await harness.store.ingest(
            self.textSnapshot(big), provenance: self.countingResolver(calls)
        ))
        #expect(first.isNew)
        #expect(first.item.useCount == 1)
        #expect(first.item.sourceURL == "https://example.com/page")
        #expect(calls.withLock { $0 } == 1)

        let blobHash = try #require(try await harness.store.representations(for: first.item.id).first?.blobHash)
        // If the recopy re-stored the blob, the file would reappear.
        try harness.blobs.delete(hash: blobHash)

        let second = try #require(try await harness.store.ingest(
            self.textSnapshot(big), provenance: self.countingResolver(calls)
        ))
        #expect(!second.isNew)
        #expect(second.item.id == first.item.id)
        #expect(second.item.useCount == 2)
        #expect(second.item.lamport > first.item.lamport)
        // Provenance of the original capture is kept, not re-fetched.
        #expect(second.item.sourceURL == "https://example.com/page")
        #expect(calls.withLock { $0 } == 1)
        #expect(!harness.blobs.exists(hash: blobHash))
    }

    @Test func secretCaptureNeverAsksForProvenance() async throws {
        let harness = try Harness()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let outcome = try #require(try await harness.store.ingest(
            self.textSnapshot("ghp_16C7e42F292c6912E7710c838347Ae178B4a"),
            provenance: self.countingResolver(calls)
        ))
        #expect(outcome.item.isSecret)
        #expect(outcome.item.sourceURL == nil)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func recopyOfSoftDeletedContentInsertsFreshItem() async throws {
        let harness = try Harness()
        let first = try #require(try await harness.store.ingest(self.textSnapshot("deleted then recopied"), provenance: nil))
        try await harness.store.delete(id: first.item.id)
        let again = try #require(try await harness.store.ingest(self.textSnapshot("deleted then recopied"), provenance: nil))
        #expect(again.isNew)
        #expect(again.item.id != first.item.id)
    }

    /// The label is computed once at ingest and persisted as `isSecret`; the
    /// enrichment pipeline reads that instead of rescanning the text. This
    /// input is only caught by the deeper `ClipSensitivity` scan (a credential
    /// embedded in a sentence), not by the classifier's own detector, so it
    /// proves the persisted flag carries the label through.
    @Test func sensitivityLabelIsPersistedAndHonoredByEnrichment() async throws {
        let harness = try Harness()
        let text = String(repeating: "Some surrounding prose to pass the length gate. ", count: 3)
            + "\n--token=ghp_16C7e42F292c6912E7710c838347Ae178B4a"
        #expect(ClipSensitivity.label(for: text) != nil)

        let outcome = try #require(try await harness.store.ingest(self.textSnapshot(text), provenance: nil))
        #expect(outcome.item.isSecret)

        let labeled = OSAllocatedUnfairLock(initialState: 0)
        let pipeline = ClipEnrichmentPipeline(
            store: harness.store,
            settings: { .init() },
            enrichText: { _ in
                labeled.withLock { $0 += 1 }
                return .init(title: "T", category: "other", summary: "S")
            }
        )
        await pipeline.enrich(item: outcome.item, snapshot: self.textSnapshot(text))
        #expect(labeled.withLock { $0 } == 0)
    }

    @Test func materializeReadsWithoutWriting() async throws {
        let harness = try Harness()
        let outcome = try #require(try await harness.store.ingest(self.textSnapshot("materialize me"), provenance: nil))
        let before = try await harness.dbWriter.read { try ClipStore.itemChangeToken(in: $0) }
        let clips = try await harness.store.materialize(itemIDs: [outcome.item.id])
        #expect(clips.count == 1)
        let after = try await harness.dbWriter.read { try ClipStore.itemChangeToken(in: $0) }
        #expect(before == after)
    }
}

/// `ClipStore.itemChangeToken` backs the drawer's live updates. It must move on
/// every mutation the drawer cares about, without scanning the tables.
struct ItemChangeTokenTests {
    private struct Harness {
        let store: ClipStore
        let dbWriter: any DatabaseWriter

        init() throws {
            let queue = try OverboardDatabase.openInMemory()
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("overboard-token-\(UUID().uuidString)", isDirectory: true)
            self.dbWriter = queue
            self.store = try ClipStore(dbWriter: queue, blobs: BlobStore(directory: dir))
        }

        func token() async throws -> Int64 {
            try await self.dbWriter.read { try ClipStore.itemChangeToken(in: $0) }
        }
    }

    private func snapshot(_ text: String) -> PasteboardSnapshot {
        PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data(text.utf8))],
            sourceBundleID: nil, sourceAppName: nil
        )
    }

    @Test func everyKindOfMutationChangesTheToken() async throws {
        let harness = try Harness()
        var last = try await harness.token()

        func expectChange(_ what: String, _ mutation: () async throws -> Void) async throws {
            try await mutation()
            let now = try await harness.token()
            #expect(now != last, "\(what) did not change the token")
            last = now
        }

        var itemID = ""
        try await expectChange("insert") {
            itemID = try #require(try await harness.store.ingest(self.snapshot("token item"))).id
        }
        try await expectChange("recopy bump") { try await harness.store.ingest(self.snapshot("token item")) }
        try await expectChange("edit (enrichment)") {
            try await harness.store.attachEnrichment(itemID: itemID, title: "Title", category: "other")
        }
        try await expectChange("pin") { try await harness.store.setPinned(id: itemID, true) }
        try await expectChange("use") { try await harness.store.markUsed(id: itemID) }
        try await expectChange("soft delete") { try await harness.store.delete(id: itemID) }
        let deletedID = itemID
        try await expectChange("restore") {
            try await harness.dbWriter.write {
                try $0.execute(sql: "UPDATE item SET deletedAt = NULL WHERE id = ?", arguments: [deletedID])
            }
        }

        var snippet = Snippet(title: "Greeting", body: "hello")
        try await expectChange("snippet insert") { snippet = try await harness.store.saveSnippet(snippet) }
        snippet.body = "hello again"
        try await expectChange("snippet edit") { snippet = try await harness.store.saveSnippet(snippet) }
        try await expectChange("snippet delete") { try await harness.store.deleteSnippet(id: snippet.id) }

        try await expectChange("hard delete") {
            try await harness.dbWriter.write { try $0.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [deletedID]) }
        }
    }

    @Test func readOnlyAccessLeavesTheTokenAlone() async throws {
        let harness = try Harness()
        try await harness.store.ingest(self.snapshot("stable"))
        let before = try await harness.token()
        _ = try await harness.store.recent(limit: 10)
        #expect(try await harness.token() == before)
    }

    @Test func observationEmitsAfterAWrite() async throws {
        let harness = try Harness()
        var iterator = harness.store.observeChangeToken().makeAsyncIterator()
        let initial = try #require(try await iterator.next())
        try await harness.store.ingest(self.snapshot("observed"))
        let updated = try #require(try await iterator.next())
        #expect(updated != initial)
    }
}
