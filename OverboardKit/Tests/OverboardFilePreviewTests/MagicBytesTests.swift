import Foundation
@testable import OverboardFilePreview
import Testing

/// `FilePreviewContentTests` covers the loader end to end; this pins the
/// signature table itself, including the cases that must *not* match so a
/// source file is never mistaken for a container.
struct MagicBytesTests {
    /// The literals are typed explicitly: Swift 6.4's type-checker gives up on
    /// an untyped array that mixes `Data([bytes])` and `Data("…".utf8)`.
    static let binarySignatures: [Data] = [
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), // PNG
        Data([0xFF, 0xD8, 0xFF, 0xE0]), // JPEG
        Data("GIF89a".utf8),
        Data("RIFF\u{00}\u{00}\u{00}\u{00}WEBP".utf8), // WebP (a RIFF container)
        Data("%PDF-1.7\n".utf8),
        Data([0x50, 0x4B, 0x03, 0x04]), // zip / docx / jar
        Data([0x1F, 0x8B, 0x08]), // gzip
        Data("SQLite format 3\u{00}".utf8),
        Data([0xCF, 0xFA, 0xED, 0xFE]), // Mach-O 64-bit
        Data([0xCA, 0xFE, 0xBA, 0xBE]), // Mach-O universal
        Data([0x7F, 0x45, 0x4C, 0x46]), // ELF
        Data("ID3\u{03}".utf8), // MP3
        Data("\u{00}\u{00}\u{00}\u{18}ftypmp42".utf8), // MP4, signature at offset 4
        Data("OggS".utf8),
        Data("fLaC".utf8),
        Data("icns".utf8),
        Data([0x42, 0x4D, 0x36, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]), // BMP
    ]

    static let plausibleText: [Data] = [
        Data("let answer = 42\n".utf8),
        Data("# Heading\n\nSome prose.\n".utf8),
        Data("{\"key\": \"value\"}".utf8),
        Data("PKG_CONFIG_PATH=/usr/lib\n".utf8), // starts with PK, but not a zip
        Data("BMW inventory,count\n".utf8), // starts with BM, but no BMP header
        Data("IDENTIFIER = 3\n".utf8), // starts with ID3? no — ID then E
        Data("GIF is a file format\n".utf8), // "GIF " — the digit matters
        Data(),
        Data([0x89]), // truncated PNG signature
    ]

    @Test(arguments: Self.binarySignatures)
    func recognizesBinarySignatures(data: Data) {
        #expect(MagicBytes.looksBinary(data))
    }

    @Test(arguments: Self.plausibleText)
    func leavesPlausibleTextAlone(data: Data) {
        #expect(!MagicBytes.looksBinary(data))
    }

    /// Signatures are matched from the slice's own start, not index zero, so a
    /// bounded `prefix(...)` sample behaves like a standalone `Data`.
    @Test func matchesAgainstASlicedSample() {
        let padded = Data([0xAA, 0xBB]) + Data("%PDF-1.4".utf8)
        #expect(MagicBytes.looksBinary(Data(padded.dropFirst(2))))
        #expect(MagicBytes.looksBinary(padded.dropFirst(2)))
        #expect(!MagicBytes.looksBinary(padded))
    }
}
