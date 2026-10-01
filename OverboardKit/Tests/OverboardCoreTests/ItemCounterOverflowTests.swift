import Foundation
import GRDB
@testable import OverboardCore
import Testing

enum ExhaustedItemMutation: CaseIterable, Sendable {
    case markUsed, pin, delete, recognizedText, enrichment, linkMetadata, sensitivity

    func apply(to store: ClipStore, itemID: String) async throws {
        switch self {
        case .markUsed: try await store.markUsed(id: itemID)
        case .pin: try await store.setPinned(id: itemID, true)
        case .delete: try await store.delete(id: itemID)
        case .recognizedText:
            try await store.attachRecognizedText(itemID: itemID, text: "new recognized text")
        case .enrichment:
            try await store.attachEnrichment(itemID: itemID, title: "New title", category: "Notes")
        case .linkMetadata:
            try await store.attachLinkMetadata(
                itemID: itemID, title: "Cached title", description: nil, faviconPNG: nil, previewImagePNG: nil
            )
        case .sensitivity:
            try await store.attachRecognizedText(itemID: itemID, text: "AKIAIOSFODNN7EXAMPLE")
        }
    }
}

struct ItemCounterOverflowTests {
    @Test(arguments: [ItemPersistenceCounter.useCount, .revision], [false, true])
    func repeatedImportedUseFailsWithoutWrapping(counter: ItemPersistenceCounter, capture: Bool) async throws {
        let source = try ArchiveHarness()
        let destination = try ArchiveHarness()
        defer { source.remove(); destination.remove() }
        let body = "repeated imported use"
        let item = try await source.text(body)
        try await source.store.export(to: source.archive)
        try source.rewriteFirstRecord {
            switch counter {
            case .useCount: $0.useCount = Int.max - 1
            case .revision: $0.lamport = Int64.max - 1
            }
        }
        _ = try await destination.store.import(from: source.archive)
        try await self.use(item.id, body: body, capture: capture, in: destination.store)
        let rows = try await destination.store.recent()
        let baseline = try #require(rows.first)
        switch counter {
        case .useCount: #expect(baseline.useCount == Int.max)
        case .revision: #expect(baseline.lamport == Int64.max)
        }
        await #expect(throws: ItemPersistenceError.counterExhausted(id: item.id, counter: counter)) {
            try await self.use(item.id, body: body, capture: capture, in: destination.store)
        }
        #expect(try await destination.store.recent() == rows)
        try await self.expectIntegerStorage(for: item.id, in: destination.database)
    }

    @Test(arguments: ExhaustedItemMutation.allCases)
    func exhaustedImportedRevisionRejectsSQLMutations(mutation: ExhaustedItemMutation) async throws {
        let source = try ArchiveHarness()
        let destination = try ArchiveHarness()
        defer { source.remove(); destination.remove() }
        let image = try await source.image()
        try await source.store.export(to: source.archive)
        try source.rewriteFirstRecord { $0.lamport = Int64.max - 1 }
        _ = try await destination.store.import(from: source.archive)
        try await destination.store.setPinned(id: image.item.id, false)
        let baseline = try await destination.store.recent()
        await #expect(throws: ItemPersistenceError.counterExhausted(id: image.item.id, counter: .revision)) {
            try await mutation.apply(to: destination.store, itemID: image.item.id)
        }
        #expect(try await destination.store.recent() == baseline)
        #expect(try await destination.store.search("new").isEmpty)
        try await self.expectIntegerStorage(for: image.item.id, in: destination.database)
    }

    @Test(arguments: [ExhaustedItemMutation.delete, .sensitivity])
    func exhaustedMutationPreservesExistingSearchIndex(mutation: ExhaustedItemMutation) async throws {
        let source = try ArchiveHarness()
        let destination = try ArchiveHarness()
        defer { source.remove(); destination.remove() }
        let item = try await source.text("original searchable body")
        try await source.store.export(to: source.archive)
        try source.rewriteFirstRecord { $0.lamport = Int64.max - 1 }
        _ = try await destination.store.import(from: source.archive)
        try await destination.store.setPinned(id: item.id, false)
        let baseline = try await destination.store.search("searchable")
        #expect(baseline.map(\.id) == [item.id])
        await #expect(throws: ItemPersistenceError.counterExhausted(id: item.id, counter: .revision)) {
            try await mutation.apply(to: destination.store, itemID: item.id)
        }
        #expect(try await destination.store.search("searchable") == baseline)
    }

    @Test func observationSupportsNearMaximumItemAndSnippetRevisions() async throws {
        let source = try ArchiveHarness()
        let destination = try ArchiveHarness()
        defer { source.remove(); destination.remove() }
        let item = try await source.text("observed imported body")
        try await source.store.saveSnippet(Snippet(title: "Observed", body: "body", lamport: Int64.max - 2))
        try await source.store.export(to: source.archive)
        try source.rewriteFirstRecord { $0.lamport = Int64.max - 1 }
        _ = try await destination.store.import(from: source.archive)
        var iterator = destination.store.observeChangeToken().makeAsyncIterator()
        let original = try await iterator.next()
        #expect(original != nil)
        try await destination.store.markUsed(id: item.id)
        let updated = try await iterator.next()
        #expect(updated != nil)
        #expect(original != updated)
    }

    private func use(_ itemID: String, body: String, capture: Bool, in store: ClipStore) async throws {
        if capture {
            try await store.ingest(PasteboardSnapshot(
                reps: [.init(uti: WellKnownUTI.plainText, data: Data(body.utf8))],
                sourceBundleID: nil, sourceAppName: nil
            ))
        } else {
            try await store.markUsed(id: itemID)
        }
    }

    private func expectIntegerStorage(for itemID: String, in database: DatabaseQueue) async throws {
        let storageTypes = try await database.read { database in
            try String.fetchOne(
                database, sql: "SELECT typeof(useCount) || ',' || typeof(lamport) FROM item WHERE id = ?",
                arguments: [itemID]
            )
        }
        #expect(storageTypes == "integer,integer")
    }
}
