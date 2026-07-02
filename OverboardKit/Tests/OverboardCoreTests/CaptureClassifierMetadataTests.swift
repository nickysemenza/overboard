import CoreGraphics
import Foundation
import GRDB
import ImageIO
@testable import OverboardCore
import Testing
import UniformTypeIdentifiers

/// A solid PNG of the given pixel dimensions, so the classifier reads real
/// image metadata back off it.
private func makePNG(width: Int, height: Int) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil
    )!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

// MARK: - Classifier metadata

struct CaptureClassifierMetadataTests {
    private func textSnapshot(_ text: String) -> PasteboardSnapshot {
        PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data(text.utf8))],
            sourceBundleID: "com.apple.TextEdit",
            sourceAppName: "TextEdit"
        )
    }

    private func imageSnapshot(width: Int, height: Int) -> PasteboardSnapshot {
        PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.png, data: makePNG(width: width, height: height))],
            sourceBundleID: "com.apple.Preview",
            sourceAppName: "Preview"
        )
    }

    private func fileSnapshot(_ paths: [String]) -> PasteboardSnapshot {
        let urls = paths.map { URL(fileURLWithPath: $0).absoluteString }
        let data = try! JSONEncoder().encode(urls)
        return PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.fileURLs, data: data)],
            sourceBundleID: "com.apple.finder",
            sourceAppName: "Finder"
        )
    }

    @Test func multilineTextCounts() {
        let result = CaptureClassifier.classify(self.textSnapshot("alpha\nbeta\ngamma"))
        #expect(result?.charCount == 16) // 3 words + 2 newlines
        #expect(result?.lineCount == 3)
    }

    @Test func singleLineTextHasOneLine() {
        let result = CaptureClassifier.classify(self.textSnapshot("just one line"))
        #expect(result?.charCount == 13)
        #expect(result?.lineCount == 1)
    }

    @Test func charCountUsesFullTextNotPreview() {
        // Beyond the 500-char preview cap: count must reflect the full payload.
        let long = String(repeating: "a", count: 2000)
        let result = CaptureClassifier.classify(self.textSnapshot(long))
        #expect(result?.charCount == 2000)
        #expect(result?.previewText?.count == 500)
    }

    @Test func imageDimensions() {
        let result = CaptureClassifier.classify(self.imageSnapshot(width: 64, height: 48))
        #expect(result?.kind == .image)
        #expect(result?.pixelWidth == 64)
        #expect(result?.pixelHeight == 48)
    }

    @Test func fileCount() {
        let result = CaptureClassifier.classify(self.fileSnapshot(["/tmp/a.pdf", "/tmp/b.txt", "/tmp/c.md"]))
        #expect(result?.kind == .file)
        #expect(result?.fileCount == 3)
    }

    @Test func nonTextKindsHaveNoCharCount() {
        #expect(CaptureClassifier.classify(self.imageSnapshot(width: 10, height: 10))?.charCount == nil)
        #expect(CaptureClassifier.classify(self.fileSnapshot(["/tmp/x"]))?.charCount == nil)
    }
}

// MARK: - metadataFooter helper

struct MetadataFooterTests {
    private func item(kind: ItemKind = .text, preview: String? = nil, isSecret: Bool = false) -> ClipItem {
        ClipItem(
            id: "id", contentHash: "hash", kind: kind, previewText: preview,
            sourceBundleID: nil, sourceAppName: nil, byteSize: 0, isSecret: isSecret,
            createdAt: .distantPast, lastUsedAt: .distantPast, updatedAt: .distantPast
        )
    }

    @Test func textWithLinesFormatsBoth() {
        var clip = self.item()
        clip.charCount = 1240
        clip.lineCount = 32
        #expect(clip.metadataFooter == "1,240 chars · 32 lines")
    }

    @Test func textOmitsLinesWhenSingleLine() {
        var clip = self.item()
        clip.charCount = 42
        clip.lineCount = 1
        #expect(clip.metadataFooter == "42 chars")
    }

    @Test func singleCharIsSingular() {
        var clip = self.item()
        clip.charCount = 1
        clip.lineCount = 1
        #expect(clip.metadataFooter == "1 char")
    }

    @Test func textWithoutCharCountIsNil() {
        #expect(self.item().metadataFooter == nil)
    }

    @Test func imageUsesColumns() {
        var clip = self.item(kind: .image)
        clip.pixelWidth = 1920
        clip.pixelHeight = 1080
        #expect(clip.metadataFooter == "1920 × 1080")
    }

    @Test func imageFallsBackToPreviewParse() {
        // No backfilled columns → parse the render-time preview string.
        let clip = self.item(kind: .image, preview: "Image 800×600")
        #expect(clip.metadataFooter == "800 × 600")
    }

    @Test func fileCountAndSize() {
        var clip = ClipItem(
            id: "id", contentHash: "hash", kind: .file, previewText: nil,
            sourceBundleID: nil, sourceAppName: nil, byteSize: 2_100_000,
            createdAt: .distantPast, lastUsedAt: .distantPast, updatedAt: .distantPast
        )
        clip.fileCount = 3
        let footer = clip.metadataFooter
        #expect(footer?.hasPrefix("3 files · ") == true)
        #expect(footer?.contains("MB") == true)
    }

    @Test func singleFileIsSingular() {
        var clip = self.item(kind: .file)
        clip.fileCount = 1
        #expect(clip.metadataFooter?.hasPrefix("1 file · ") == true)
    }

    @Test func linkAndColorAreNil() {
        var link = self.item(kind: .link)
        link.charCount = 100
        #expect(link.metadataFooter == nil)
        #expect(self.item(kind: .color).metadataFooter == nil)
    }

    @Test func secretIsNeverShown() {
        var clip = self.item(isSecret: true)
        clip.charCount = 500
        clip.lineCount = 10
        #expect(clip.metadataFooter == nil)
    }
}
