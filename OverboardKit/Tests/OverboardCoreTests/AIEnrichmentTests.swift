import CoreGraphics
import CoreText
import Foundation
import ImageIO
@testable import OverboardCore
import Testing
import UniformTypeIdentifiers

struct ImageTextRecognizerTests {
    /// Renders a crisp black-on-white label and expects OCR to read it back.
    private func renderTextImage(_ text: String) -> Data? {
        let width = 1000, height = 120
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica" as CFString, 48, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 20, y: 40)
        CTLineDraw(line, context)

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @Test func readsTextFromImage() throws {
        let png = try #require(renderTextImage("INVOICE 2024 OVERBOARD"))
        let recognized = ImageTextRecognizer.recognizeText(in: png)
        let normalized = recognized?.uppercased() ?? ""
        #expect(normalized.contains("INVOICE"))
        #expect(normalized.contains("OVERBOARD"))
    }

    @Test func returnsNilForBlankImage() throws {
        let width = 100, height = 100
        let context = try #require(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)

        #expect(ImageTextRecognizer.recognizeText(in: data as Data) == nil)
    }
}

struct EnrichmentStoreTests {
    private func makeStore() throws -> ClipStore {
        let queue = try OverboardDatabase.openInMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-ai-\(UUID().uuidString)", isDirectory: true)
        return try ClipStore(dbWriter: queue, blobs: BlobStore(directory: dir))
    }

    private func imageSnapshot() -> PasteboardSnapshot {
        // 1x1 transparent png
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        return PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.png, data: png)],
            sourceBundleID: "com.test",
            sourceAppName: "Test"
        )
    }

    @Test func recognizedTextMakesImagesSearchable() async throws {
        let store = try makeStore()
        let item = try #require(try await store.ingest(self.imageSnapshot()))

        // Images start unsearchable.
        #expect(try await store.search("receipt").isEmpty)

        try await store.attachRecognizedText(itemID: item.id, text: "Total receipt amount $42.50")
        let found = try await store.search("receipt")
        #expect(found.count == 1)
        #expect(found.first?.id == item.id)
    }

    @Test func attachRecognizedTextNeverOverwrites() async throws {
        let store = try makeStore()
        let textSnapshot = PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data("original words".utf8))],
            sourceBundleID: nil,
            sourceAppName: nil
        )
        let item = try #require(try await store.ingest(textSnapshot))

        try await store.attachRecognizedText(itemID: item.id, text: "should be ignored")
        #expect(try await store.search("ignored").isEmpty)
        #expect(try await store.search("original").count == 1)
    }

    @Test func enrichmentMakesTitleAndSummarySearchable() async throws {
        let store = try makeStore()
        let snapshot = PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data("0, 1, 1, 2, 3, 5, 8, 13, 21".utf8))],
            sourceBundleID: nil,
            sourceAppName: nil
        )
        let item = try #require(try await store.ingest(snapshot))

        // Before enrichment: only the literal content matches.
        #expect(try await store.search("fibonacci").isEmpty)

        try await store.attachEnrichment(
            itemID: item.id,
            title: "Fibonacci Sequence",
            category: "code",
            summary: "The first numbers of the famous series."
        )

        // Title, summary, AND original content all match now.
        #expect(try await store.search("fibonacci").count == 1)
        #expect(try await store.search("famous").count == 1)
        #expect(try await store.search("21").count == 1)
    }

    @Test func enrichedImageSearchableByOCRAndTitle() async throws {
        let store = try makeStore()
        let item = try #require(try await store.ingest(self.imageSnapshot()))

        try await store.attachRecognizedText(itemID: item.id, text: "GUEST WIFI dockside42")
        try await store.attachEnrichment(itemID: item.id, title: "Wifi Credentials", category: "other")

        #expect(try await store.search("dockside42").count == 1)
        #expect(try await store.search("credentials").count == 1)
    }

    @Test func enrichmentStoresTitleAndCategoryOnce() async throws {
        let store = try makeStore()
        let snapshot = PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data("some long enough text".utf8))],
            sourceBundleID: nil,
            sourceAppName: nil
        )
        let item = try #require(try await store.ingest(snapshot))

        try await store.attachEnrichment(
            itemID: item.id, title: "First Title", category: "prose", summary: "A summary."
        )
        try await store.attachEnrichment(itemID: item.id, title: "Second Title", category: "code")

        let recent = try await store.recent(limit: 5)
        #expect(recent.first?.aiTitle == "First Title")
        #expect(recent.first?.category == "prose")
        #expect(recent.first?.aiSummary == "A summary.")
    }
}
