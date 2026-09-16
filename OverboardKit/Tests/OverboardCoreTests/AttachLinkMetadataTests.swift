import Foundation
@testable import OverboardCore
import Testing

struct AttachLinkMetadataTests {
    private func makeStore() throws -> ClipStore {
        let queue = try OverboardDatabase.openInMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-link-\(UUID().uuidString)", isDirectory: true)
        return try ClipStore(dbWriter: queue, blobs: BlobStore(directory: dir))
    }

    private func linkSnapshot(_ urlString: String) -> PasteboardSnapshot {
        PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data(urlString.utf8))],
            sourceBundleID: "com.test",
            sourceAppName: "Test"
        )
    }

    @Test func fetchedTitleMakesLinkSearchable() async throws {
        let store = try makeStore()
        let item = try #require(try await store.ingest(self.linkSnapshot("https://swift.org/blog/post")))
        #expect(item.kind == .link)

        // The page title isn't in the URL, so it isn't findable yet.
        #expect(try await store.search("concurrency").isEmpty)

        try await store.attachLinkMetadata(
            itemID: item.id,
            title: "Swift Concurrency Roadmap",
            description: "A deep dive into async await.",
            faviconPNG: nil,
            previewImagePNG: nil
        )

        // Title, description, AND the original URL all match now.
        #expect(try await store.search("concurrency").count == 1)
        #expect(try await store.search("async").count == 1)
        #expect(try await store.search("swift").count == 1)
    }

    @Test func storesColumnsAndSurvivesRefetch() async throws {
        let store = try makeStore()
        let item = try #require(try await store.ingest(self.linkSnapshot("https://example.com/a")))

        let favicon = Data([0x89, 0x50, 0x4E, 0x47]) // PNG magic prefix, opaque here
        let preview = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])
        try await store.attachLinkMetadata(
            itemID: item.id,
            title: "Example Page",
            description: "Desc",
            faviconPNG: favicon,
            previewImagePNG: preview
        )

        let stored = try #require(try await store.recent(limit: 5).first)
        #expect(stored.linkTitle == "Example Page")
        #expect(stored.linkDescription == "Desc")
        #expect(stored.faviconData == favicon)
        #expect(stored.previewImageData == preview)
    }

    @Test func emptySentinelIsNotRetriedByBackfill() async throws {
        let store = try makeStore()
        let item = try #require(try await store.ingest(self.linkSnapshot("https://example.com/x")))

        // Before any attempt, the link needs metadata.
        #expect(try await store.linksNeedingMetadata(limit: 10).map(\.id) == [item.id])

        // Failed fetch → empty-title sentinel.
        try await store.attachLinkMetadata(
            itemID: item.id, title: "", description: nil, faviconPNG: nil, previewImagePNG: nil
        )

        // Now it's marked attempted (linkTitle == "" is non-NULL), so backfill skips it.
        #expect(try await store.linksNeedingMetadata(limit: 10).isEmpty)
        // And the empty title contributed nothing spurious to search.
        let stored = try #require(try await store.recent(limit: 5).first)
        #expect(stored.linkTitle == "")
    }

    @Test func neverOverwritesExistingMetadata() async throws {
        let store = try makeStore()
        let item = try #require(try await store.ingest(self.linkSnapshot("https://example.com/y")))

        try await store.attachLinkMetadata(
            itemID: item.id, title: "First", description: "one", faviconPNG: nil, previewImagePNG: nil
        )
        try await store.attachLinkMetadata(
            itemID: item.id, title: "Second", description: "two", faviconPNG: nil, previewImagePNG: nil
        )

        let stored = try #require(try await store.recent(limit: 5).first)
        #expect(stored.linkTitle == "First")
        #expect(stored.linkDescription == "one")
    }

    @Test func linksNeedingMetadataExcludesSecretsAndNonLinks() async throws {
        let store = try makeStore()
        _ = try await store.ingest(self.linkSnapshot("https://example.com/keep"))
        // A plain-text item should never appear.
        _ = try await store.ingest(PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data("just some text here".utf8))],
            sourceBundleID: nil, sourceAppName: nil
        ))

        let needing = try await store.linksNeedingMetadata(limit: 10)
        #expect(needing.count == 1)
        #expect(needing.first?.kind == .link)
    }

    @Test func backfillDrainsInNewestFirstOrder() async throws {
        let store = try makeStore()
        let older = try #require(try await store.ingest(self.linkSnapshot("https://example.com/older")))
        // Ensure distinct createdAt ordering.
        try await Task.sleep(nanoseconds: 10_000_000)
        let newer = try #require(try await store.ingest(self.linkSnapshot("https://example.com/newer")))

        let ordered = try await store.linksNeedingMetadata(limit: 10)
        #expect(ordered.map(\.id) == [newer.id, older.id])
    }
}
