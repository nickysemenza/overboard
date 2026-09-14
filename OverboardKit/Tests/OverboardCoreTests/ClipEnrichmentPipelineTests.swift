import Foundation
@testable import OverboardCore
import Testing

/// Records what the pipeline asked the outside world to do, so the tests can
/// assert on the guards (secret, duplicate, too short, setting off) that decide
/// whether OCR / a network fetch / an LLM call happens at all.
private actor SeamCalls {
    var recognized: [Data] = []
    var fetched: [URL] = []
    var labeled: [String] = []

    func recognize(_ data: Data) {
        self.recognized.append(data)
    }

    func fetch(_ url: URL) {
        self.fetched.append(url)
    }

    func label(_ text: String) {
        self.labeled.append(text)
    }
}

struct ClipEnrichmentPipelineTests {
    private func makeStore() throws -> ClipStore {
        let queue = try OverboardDatabase.openInMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-enrich-\(UUID().uuidString)", isDirectory: true)
        return try ClipStore(dbWriter: queue, blobs: BlobStore(directory: dir))
    }

    private func textSnapshot(_ text: String) -> PasteboardSnapshot {
        PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data(text.utf8))],
            sourceBundleID: "com.test",
            sourceAppName: "Test"
        )
    }

    private func pngSnapshot(_ data: Data) -> PasteboardSnapshot {
        PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.png, data: data)],
            sourceBundleID: "com.test",
            sourceAppName: "Test"
        )
    }

    /// A pipeline whose three outside-world steps are stubs recorded in `calls`.
    private func makePipeline(
        store: ClipStore,
        calls: SeamCalls,
        settings: ClipEnrichmentPipeline.Settings = .init(richLinkPreviews: true),
        recognized: String? = nil,
        metadata: LinkMetadata? = nil,
        enrichment: ClipEnricher.Enrichment? = nil
    ) -> ClipEnrichmentPipeline {
        ClipEnrichmentPipeline(
            store: store,
            settings: { settings },
            recognizeText: { data in
                await calls.recognize(data)
                return recognized
            },
            fetchLink: { url in
                await calls.fetch(url)
                return metadata
            },
            enrichText: { text in
                await calls.label(text)
                return enrichment
            }
        )
    }

    private func reload(_ id: String, from store: ClipStore) async throws -> ClipItem {
        let items = try await store.recent(limit: 100)
        return try #require(items.first { $0.id == id })
    }

    private func longText(_ count: Int) -> String {
        String(repeating: "the quick brown fox jumps over the lazy dog. ", count: count / 45 + 1)
            .prefix(count)
            .description
    }

    // MARK: - Text labeling

    @Test func longTextClipIsLabeled() async throws {
        let store = try self.makeStore()
        let calls = SeamCalls()
        let text = self.longText(120)
        let snapshot = self.textSnapshot(text)
        let item = try #require(try await store.ingest(snapshot))

        let pipeline = self.makePipeline(
            store: store,
            calls: calls,
            enrichment: .init(title: "Pangram Practice", category: "prose", summary: "A pangram.")
        )
        await pipeline.enrich(item: item, snapshot: snapshot)

        let enriched = try await self.reload(item.id, from: store)
        #expect(enriched.aiTitle == "Pangram Practice")
        #expect(enriched.category == "prose")
        // Under the summary-worthwhile length, so the card shows the clip itself.
        #expect(enriched.aiSummary == nil)
        #expect(await calls.labeled.count == 1)
    }

    @Test func summaryIsStoredOnlyForLongClips() async throws {
        let store = try self.makeStore()
        let calls = SeamCalls()
        let text = self.longText(ClipEnricher.summaryWorthwhileLength + 50)
        let snapshot = self.textSnapshot(text)
        let item = try #require(try await store.ingest(snapshot))

        let pipeline = self.makePipeline(
            store: store,
            calls: calls,
            enrichment: .init(title: "Long Pangrams", category: "prose", summary: "Lots of foxes.")
        )
        await pipeline.enrich(item: item, snapshot: snapshot)

        #expect(try await self.reload(item.id, from: store).aiSummary == "Lots of foxes.")
    }

    @Test func shortTextIsNotLabeled() async throws {
        let store = try self.makeStore()
        let calls = SeamCalls()
        let snapshot = self.textSnapshot("too short to label")
        let item = try #require(try await store.ingest(snapshot))

        let pipeline = self.makePipeline(
            store: store,
            calls: calls,
            enrichment: .init(title: "Nope", category: "other", summary: "Nope.")
        )
        await pipeline.enrich(item: item, snapshot: snapshot)

        #expect(await calls.labeled.isEmpty)
        #expect(try await self.reload(item.id, from: store).aiTitle == nil)
    }

    @Test func unavailableModelLeavesClipUnlabeled() async throws {
        let store = try self.makeStore()
        let calls = SeamCalls()
        let snapshot = self.textSnapshot(self.longText(120))
        let item = try #require(try await store.ingest(snapshot))

        // No `enrichment` passed → the enrichText stub returns nil, standing
        // in for Apple Intelligence being unavailable on this Mac.
        let pipeline = self.makePipeline(store: store, calls: calls, enrichment: nil)
        await pipeline.enrich(item: item, snapshot: snapshot)

        #expect(await calls.labeled.count == 1)
        #expect(try await self.reload(item.id, from: store).aiTitle == nil)
    }

    // MARK: - Secrets and duplicates

    @Test func secretsAreNeverEnriched() async throws {
        let store = try self.makeStore()
        let calls = SeamCalls()
        // Long enough to label, but a detected credential — nothing about it
        // should reach OCR, the network, or the model.
        let snapshot = self.textSnapshot("ghp_16C7e42F292c6912E7710c838347Ae178B4a")
        let item = try #require(try await store.ingest(snapshot))
        #expect(item.isSecret)

        let pipeline = self.makePipeline(
            store: store,
            calls: calls,
            enrichment: .init(title: "Nope", category: "other", summary: "Nope.")
        )
        await pipeline.enrich(item: item, snapshot: snapshot)

        #expect(await calls.labeled.isEmpty)
        #expect(await calls.fetched.isEmpty)
        #expect(await calls.recognized.isEmpty)
    }

    @Test func bumpedDuplicateIsNotReenriched() async throws {
        let store = try self.makeStore()
        let calls = SeamCalls()
        let snapshot = self.textSnapshot(self.longText(120))
        _ = try await store.ingest(snapshot)
        // Re-copying the same content bumps the existing row instead of
        // inserting; it was already enriched on the first pass.
        let bumped = try #require(try await store.ingest(snapshot))
        #expect(bumped.useCount == 2)

        let pipeline = self.makePipeline(
            store: store,
            calls: calls,
            enrichment: .init(title: "Nope", category: "other", summary: "Nope.")
        )
        await pipeline.enrich(item: bumped, snapshot: snapshot)

        #expect(await calls.labeled.isEmpty)
    }

    // MARK: - Links

    @Test func linkClipAttachesFetchedMetadata() async throws {
        let store = try self.makeStore()
        let calls = SeamCalls()
        let snapshot = self.textSnapshot("https://swift.org/blog/post")
        let item = try #require(try await store.ingest(snapshot))
        #expect(item.kind == .link)

        let pipeline = self.makePipeline(
            store: store,
            calls: calls,
            metadata: LinkMetadata(title: "Swift Blog", description: "Posts about Swift.")
        )
        await pipeline.enrich(item: item, snapshot: snapshot)

        let enriched = try await self.reload(item.id, from: store)
        #expect(enriched.linkTitle == "Swift Blog")
        #expect(enriched.linkDescription == "Posts about Swift.")
        #expect(await calls.fetched.map(\.absoluteString) == ["https://swift.org/blog/post"])
    }

    @Test func unfetchableLinkGetsTheAttemptedSentinelWithoutFetching() async throws {
        let store = try self.makeStore()
        let calls = SeamCalls()
        // A private-network host: never fetched (SSRF hardening), but still
        // marked attempted so backfill doesn't re-check it every pass.
        let snapshot = self.textSnapshot("http://192.168.1.10/admin")
        let item = try #require(try await store.ingest(snapshot))
        #expect(item.kind == .link)

        let pipeline = self.makePipeline(
            store: store,
            calls: calls,
            metadata: LinkMetadata(title: "Should never be used")
        )
        await pipeline.enrich(item: item, snapshot: snapshot)

        #expect(try await self.reload(item.id, from: store).linkTitle == "")
        #expect(await calls.fetched.isEmpty)
    }

    @Test func richLinkPreviewsOffSkipsTheFetch() async throws {
        let store = try self.makeStore()
        let calls = SeamCalls()
        let snapshot = self.textSnapshot("https://swift.org/blog/post")
        let item = try #require(try await store.ingest(snapshot))

        let pipeline = self.makePipeline(
            store: store,
            calls: calls,
            settings: .init(richLinkPreviews: false),
            metadata: LinkMetadata(title: "Swift Blog")
        )
        await pipeline.enrich(item: item, snapshot: snapshot)

        #expect(await calls.fetched.isEmpty)
        // No sentinel either — the link is untouched, so enabling the setting
        // later still picks it up.
        #expect(try await self.reload(item.id, from: store).linkTitle == nil)
    }

    /// Backfill calls this directly, bypassing `enrich`.
    @Test func fetchLinkMetadataAttachesWithoutTheSettingGate() async throws {
        let store = try self.makeStore()
        let calls = SeamCalls()
        let item = try #require(try await store.ingest(self.textSnapshot("https://example.com/a")))

        let pipeline = self.makePipeline(
            store: store,
            calls: calls,
            metadata: LinkMetadata(title: "Example")
        )
        await pipeline.fetchLinkMetadata(for: item)

        #expect(try await self.reload(item.id, from: store).linkTitle == "Example")
    }

    @Test func refetchLinkMetadataResetsThenRefetchesMatchingItems() async throws {
        let store = try self.makeStore()
        let calls = SeamCalls()
        let underOrigin = try #require(try await store.ingest(self.textSnapshot("https://wiki.x/a")))
        let elsewhere = try #require(try await store.ingest(self.textSnapshot("https://example.com/x")))
        for item in [underOrigin, elsewhere] {
            try await store.attachLinkMetadata(
                itemID: item.id, title: "Sign in ・ Cloudflare Access", description: nil,
                faviconPNG: nil, previewImagePNG: nil
            )
        }

        let pipeline = self.makePipeline(store: store, calls: calls, metadata: LinkMetadata(title: "Wiki Home"))
        await pipeline.refetchLinkMetadata(origin: "https://wiki.x")

        // Only the item under the origin was reset and re-fetched…
        #expect(await calls.fetched.map(\.absoluteString) == ["https://wiki.x/a"])
        #expect(try await self.reload(underOrigin.id, from: store).linkTitle == "Wiki Home")
        // …the other host's link is untouched.
        #expect(try await self.reload(elsewhere.id, from: store).linkTitle == "Sign in ・ Cloudflare Access")
    }

    // MARK: - Images

    @Test func imageClipAttachesRecognizedText() async throws {
        let store = try self.makeStore()
        let calls = SeamCalls()
        let snapshot = self.pngSnapshot(Data(repeating: 0x42, count: 64))
        let item = try #require(try await store.ingest(snapshot))
        #expect(item.kind == .image)

        let pipeline = self.makePipeline(store: store, calls: calls, recognized: "INVOICE OVERBOARD")
        await pipeline.enrich(item: item, snapshot: snapshot)

        #expect(await calls.recognized.count == 1)
        // The OCR text is in FTS, which is the point of attaching it.
        #expect(try await store.search("invoice").count == 1)
    }

    @Test func textlessImageIsStillMarkedOCRAttempted() async throws {
        let store = try self.makeStore()
        let calls = SeamCalls()
        let snapshot = self.pngSnapshot(Data(repeating: 0x7F, count: 64))
        let item = try #require(try await store.ingest(snapshot))

        // nil recognition still writes '' so the item isn't re-OCR'd forever.
        let pipeline = self.makePipeline(store: store, calls: calls, recognized: nil)
        await pipeline.enrich(item: item, snapshot: snapshot)

        #expect(await calls.recognized.count == 1)
        #expect(await calls.labeled.isEmpty)
    }
}
