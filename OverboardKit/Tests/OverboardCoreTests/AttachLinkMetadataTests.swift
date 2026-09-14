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

    @Test func resetLinkMetadataHealsOnlyMatchingRows() async throws {
        let store = try makeStore()
        let brokenLink = try #require(
            try await store.ingest(self.linkSnapshot("https://internal.example.com/wiki"))
        )
        let goodLink = try #require(
            try await store.ingest(self.linkSnapshot("https://example.com/real"))
        )

        try await store.attachLinkMetadata(
            itemID: brokenLink.id,
            title: "Sign in ・ Cloudflare Access",
            description: nil,
            faviconPNG: nil,
            previewImagePNG: nil
        )
        try await store.attachLinkMetadata(
            itemID: goodLink.id,
            title: "Real page",
            description: "A genuinely fetched page.",
            faviconPNG: nil,
            previewImagePNG: nil
        )
        // Both are attempted, so neither needs a fetch right now.
        #expect(try await store.linksNeedingMetadata(limit: 10).isEmpty)

        let healed = try await store.resetLinkMetadata(whereTitleContains: "Cloudflare Access")
        #expect(healed == 1)

        // The broken link is back in the backfill queue…
        #expect(try await store.linksNeedingMetadata(limit: 10).map(\.id) == [brokenLink.id])
        let reset = try #require(try await store.recent(limit: 10).first { $0.id == brokenLink.id })
        #expect(reset.linkTitle == nil)
        #expect(reset.linkDescription == nil)
        #expect(reset.faviconData == nil)
        #expect(reset.previewImageData == nil)
        // …and its own URL is still searchable even though its bad title was
        // cleared out of the index.
        #expect(try await store.search("internal.example.com").count == 1)

        // The good link is untouched.
        let untouched = try #require(try await store.recent(limit: 10).first { $0.id == goodLink.id })
        #expect(untouched.linkTitle == "Real page")
        #expect(try await store.search("Real page").count == 1)
    }

    @Test func resetLinkMetadataForOriginHealsOnlyMatchingURLs() async throws {
        let store = try makeStore()
        // Under "https://wiki.x": the origin itself, and a path beneath it.
        let exact = try #require(try await store.ingest(self.linkSnapshot("https://wiki.x")))
        let nested = try #require(try await store.ingest(self.linkSnapshot("https://wiki.x/a")))
        // Must NOT match: a different (if similar-prefixed) host, and the
        // same path segment under an unrelated host.
        let similarHost = try #require(try await store.ingest(self.linkSnapshot("https://wiki.xyz/a")))
        let unrelatedHost = try #require(try await store.ingest(self.linkSnapshot("https://other/wiki.x")))

        for item in [exact, nested, similarHost, unrelatedHost] {
            try await store.attachLinkMetadata(
                itemID: item.id, title: "Sign in ・ Cloudflare Access", description: nil,
                faviconPNG: nil, previewImagePNG: nil
            )
        }
        // All four are attempted, so none need a fetch right now.
        #expect(try await store.linksNeedingMetadata(limit: 10).isEmpty)

        let healed = try await store.resetLinkMetadata(forOrigin: "https://wiki.x")
        #expect(Set(healed.map(\.id)) == Set([exact.id, nested.id]))

        // Only the two under "https://wiki.x" are back in the backfill queue…
        #expect(try await Set(store.linksNeedingMetadata(limit: 10).map(\.id)) == Set([exact.id, nested.id]))

        let all = try await store.recent(limit: 10)
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        #expect(byID[exact.id]?.linkTitle == nil)
        #expect(byID[nested.id]?.linkTitle == nil)
        // …the unrelated hosts are untouched.
        #expect(byID[similarHost.id]?.linkTitle == "Sign in ・ Cloudflare Access")
        #expect(byID[unrelatedHost.id]?.linkTitle == "Sign in ・ Cloudflare Access")
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
