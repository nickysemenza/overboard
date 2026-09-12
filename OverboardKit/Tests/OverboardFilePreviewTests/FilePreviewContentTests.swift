import Foundation
@testable import OverboardFilePreview
import Testing
import UniformTypeIdentifiers

struct FilePreviewContentTests {
    @Test(arguments: ["swift", "yml", "json", "md", "txt", "log", "csv", "tsv"])
    func supportsReadableTextExtensions(extensionName: String) {
        #expect(FilePreviewEligibility.supports(URL(fileURLWithPath: "/tmp/example.\(extensionName)")))
    }

    @Test(arguments: ["pdf", "png", "docx", "numbers", "zip", "sqlite", "app"])
    func preservesRichAndBinaryFormats(extensionName: String) {
        #expect(!FilePreviewEligibility.supports(URL(fileURLWithPath: "/tmp/example.\(extensionName)")))
    }

    @Test func inferredPlainTextFallbackDoesNotBroadenToRichText() {
        #expect(FilePreviewEligibility.supportsInferredPlainTextType(UTType.plainText.identifier))
        #expect(!FilePreviewEligibility.supportsInferredPlainTextType(UTType.rtf.identifier))
    }

    @Test func decodesUTF16AndCapsLargeSource() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).swift")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = String(repeating: "let café = 1\n", count: 3000)
        let data = try #require(source.data(using: .utf16LittleEndian))
        try data.write(to: url)
        let preview = try FilePreviewLoader.load(url)
        #expect(preview.text.contains("café"))
        #expect(preview.isTruncated)
        #expect(preview.text.count == FilePreviewContent.maximumDisplayedCharacters)
    }

    @Test func rejectsBinaryContent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0, 1, 2, 3]).write(to: url)
        #expect(throws: FilePreviewLoadError.binary) { try FilePreviewLoader.load(url) }
    }

    @Test(arguments: [
        Data("%PDF-1.7\n".utf8),
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        Data([0x50, 0x4B, 0x03, 0x04]),
        Data("SQLite format 3\0".utf8),
    ])
    func rejectsRecognizedBinaryDisguisedAsText(data: Data) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)

        #expect(throws: FilePreviewLoadError.binary) { try FilePreviewLoader.load(url) }
    }

    @Test func explicitSourceExtensionWinsOverSystemTransportStreamType() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).ts")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("const preview = true\n".utf8).write(to: url)

        let preview = try FilePreviewLoader.load(url)

        #expect(preview.language == "typescript")
        #expect(preview.text.contains("preview"))
    }

    @Test func reportsMissingFilesAsUnreadable() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).txt")
        #expect(throws: FilePreviewLoadError.unreadable) { try FilePreviewLoader.load(url) }
    }
}
