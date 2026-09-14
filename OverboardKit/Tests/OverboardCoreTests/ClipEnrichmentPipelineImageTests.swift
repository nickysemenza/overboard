import Foundation
@testable import OverboardCore
import Testing

/// Records what the pipeline asked the outside world to do. Split out from
/// `ClipEnrichmentPipelineTests`' own `SeamCalls` (SwiftLint's file/type
/// length ceilings) — this one additionally tracks calls to `enrichImage`,
/// the macOS 27 image-labeling seam.
private actor ImageSeamCalls {
    var recognized: [Data] = []
    var labeled: [String] = []
    var imageLabeled: [(data: Data, hint: String?)] = []

    func recognize(_ data: Data) {
        self.recognized.append(data)
    }

    func label(_ text: String) {
        self.labeled.append(text)
    }

    func labelImage(_ data: Data, hint: String?) {
        self.imageLabeled.append((data, hint))
    }
}

/// The macOS 27 image-enrichment path: `ClipEnrichmentPipeline`'s
/// `enrichImage` seam labels an image clip straight from its pixels,
/// replacing the OCR-text-only path tested in `ClipEnrichmentPipelineTests`.
struct ClipEnrichmentPipelineImageTests {
    private func makeStore() throws -> ClipStore {
        let queue = try OverboardDatabase.openInMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-enrich-image-\(UUID().uuidString)", isDirectory: true)
        return try ClipStore(dbWriter: queue, blobs: BlobStore(directory: dir))
    }

    private func pngSnapshot(_ data: Data) -> PasteboardSnapshot {
        PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.png, data: data)],
            sourceBundleID: "com.test",
            sourceAppName: "Test"
        )
    }

    /// A pipeline whose `enrichImage` is always installed, recording calls
    /// and outcomes in `calls`/`imageEnrichment`. `imageEnrichment == nil`
    /// stands in for the model being unavailable or the request failing —
    /// the seam is still called, it just returns nothing.
    private func makePipeline(
        store: ClipStore,
        calls: ImageSeamCalls,
        recognized: String? = nil,
        imageEnrichment: ClipEnricher.Enrichment? = nil
    ) -> ClipEnrichmentPipeline {
        ClipEnrichmentPipeline(
            store: store,
            settings: { .init(richLinkPreviews: true) },
            recognizeText: { data in
                await calls.recognize(data)
                return recognized
            },
            enrichText: { text in
                await calls.label(text)
                return nil
            },
            enrichImage: { data, hint in
                await calls.labelImage(data, hint: hint)
                return imageEnrichment
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

    @Test func imageClipWithOCRTextIsLabeledByImageEnricher() async throws {
        let store = try self.makeStore()
        let calls = ImageSeamCalls()
        let png = Data(repeating: 0x42, count: 64)
        let snapshot = self.pngSnapshot(png)
        let item = try #require(try await store.ingest(snapshot))

        let pipeline = self.makePipeline(
            store: store,
            calls: calls,
            recognized: "INVOICE OVERBOARD",
            imageEnrichment: .init(title: "Invoice Screenshot", category: "other", summary: "An invoice.")
        )
        await pipeline.enrich(item: item, snapshot: snapshot)

        let calledWith = await calls.imageLabeled
        #expect(calledWith.count == 1)
        #expect(calledWith.first?.data == png)
        #expect(calledWith.first?.hint == "INVOICE OVERBOARD")
        // The image path replaces the text path entirely once enrichImage is set.
        #expect(await calls.labeled.isEmpty)

        let enriched = try await self.reload(item.id, from: store)
        #expect(enriched.aiTitle == "Invoice Screenshot")
        #expect(enriched.category == "other")
    }

    @Test func textlessImageIsStillLabeledByImageEnricher() async throws {
        let store = try self.makeStore()
        let calls = ImageSeamCalls()
        let snapshot = self.pngSnapshot(Data(repeating: 0x7F, count: 64))
        let item = try #require(try await store.ingest(snapshot))

        // No OCR text at all — the text-only path would never label this;
        // the image enricher sees pixels alone and still can.
        let pipeline = self.makePipeline(
            store: store,
            calls: calls,
            recognized: nil,
            imageEnrichment: .init(title: "Blank Screenshot", category: "other", summary: "Nothing legible.")
        )
        await pipeline.enrich(item: item, snapshot: snapshot)

        let calledWith = await calls.imageLabeled
        #expect(calledWith.count == 1)
        #expect(calledWith.first?.hint == nil)

        #expect(try await self.reload(item.id, from: store).aiTitle == "Blank Screenshot")
    }

    @Test func secretImageIsNeverEnriched() async throws {
        let store = try self.makeStore()
        let calls = ImageSeamCalls()
        let png = Data(repeating: 0x42, count: 64)
        let snapshot = self.pngSnapshot(png)

        // The classifier never flags an image kind secret (only `.text`
        // /`.link` are scanned for credential patterns), so build the item
        // directly to exercise the pipeline's `!item.isSecret` guard, which
        // runs ahead of any kind check.
        let item = ClipItem(
            contentHash: "secret-image", kind: .image, previewText: "Secret — Screenshot",
            sourceBundleID: "com.test", sourceAppName: "Test", byteSize: png.count,
            isSecret: true, createdAt: Date(), lastUsedAt: Date(), updatedAt: Date()
        )

        let pipeline = self.makePipeline(
            store: store,
            calls: calls,
            imageEnrichment: .init(title: "Nope", category: "other", summary: "Nope.")
        )
        await pipeline.enrich(item: item, snapshot: snapshot)

        #expect(await calls.imageLabeled.isEmpty)
        #expect(await calls.recognized.isEmpty)
    }

    @Test func summaryOnlyAttachedForImageWhenOCRTextIsLong() async throws {
        let store = try self.makeStore()
        let calls = ImageSeamCalls()
        let longText = self.longText(ClipEnricher.summaryWorthwhileLength + 50)
        let snapshot = self.pngSnapshot(Data(repeating: 0x11, count: 64))
        let item = try #require(try await store.ingest(snapshot))

        let pipeline = self.makePipeline(
            store: store,
            calls: calls,
            recognized: longText,
            imageEnrichment: .init(title: "Long Screenshot", category: "other", summary: "Lots of text.")
        )
        await pipeline.enrich(item: item, snapshot: snapshot)

        #expect(try await self.reload(item.id, from: store).aiSummary == "Lots of text.")
    }

    @Test func summaryNotAttachedForImageWhenOCRTextIsShort() async throws {
        let store = try self.makeStore()
        let calls = ImageSeamCalls()
        let snapshot = self.pngSnapshot(Data(repeating: 0x11, count: 64))
        let item = try #require(try await store.ingest(snapshot))

        let pipeline = self.makePipeline(
            store: store,
            calls: calls,
            recognized: "short caption",
            imageEnrichment: .init(title: "Short Screenshot", category: "other", summary: "A short caption.")
        )
        await pipeline.enrich(item: item, snapshot: snapshot)

        #expect(try await self.reload(item.id, from: store).aiSummary == nil)
    }
}
