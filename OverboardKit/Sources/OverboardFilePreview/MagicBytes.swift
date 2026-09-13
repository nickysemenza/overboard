import Foundation

/// Leading-byte signatures for the binary container formats a file with a
/// text-looking extension might actually be. The text preview consults this
/// before decoding, so a renamed PDF or zip is refused rather than rendered as
/// mojibake.
///
/// Deliberately signature-only: the complementary "this decoded to control
/// characters" check runs *after* decoding, because UTF-16 text is full of NUL
/// bytes and would fail any pre-decode NUL heuristic.
public nonisolated enum MagicBytes {
    /// A signature is a byte run expected at a fixed offset. `trailing` adds a
    /// second run for formats whose first bytes are too generic on their own.
    struct Signature {
        let offset: Int
        let bytes: [UInt8]
        let trailing: (offset: Int, bytes: [UInt8])?

        static func bytes(
            _ bytes: [UInt8],
            at offset: Int = 0,
            trailing: (offset: Int, bytes: [UInt8])? = nil
        ) -> Signature {
            Signature(offset: offset, bytes: bytes, trailing: trailing)
        }

        static func ascii(
            _ string: String,
            at offset: Int = 0,
            trailing: (offset: Int, bytes: [UInt8])? = nil
        ) -> Signature {
            Signature(offset: offset, bytes: Array(string.utf8), trailing: trailing)
        }
    }

    static let signatures: [Signature] = [
        // Images
        .bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), // PNG
        .bytes([0xFF, 0xD8, 0xFF]), // JPEG
        .ascii("GIF8"), // GIF87a / GIF89a
        .ascii("RIFF"), // WebP, WAV, AVI — all RIFF containers
        .bytes([0x49, 0x49, 0x2A, 0x00]), // TIFF little-endian
        .bytes([0x4D, 0x4D, 0x00, 0x2A]), // TIFF big-endian
        // "BM" alone is two plausible letters, so also require BMP's reserved
        // header field (bytes 6–9) to be zero.
        .ascii("BM", trailing: (6, [0, 0, 0, 0])),
        .ascii("icns"), // Apple icon image

        // Documents and archives
        .ascii("%PDF-"),
        .ascii("PK\u{03}\u{04}"), // zip, and everything built on it: jar, docx, xlsx, ipa
        .ascii("PK\u{05}\u{06}"), // empty zip
        .ascii("PK\u{07}\u{08}"), // spanned zip
        .bytes([0x1F, 0x8B]), // gzip
        .ascii("BZh"), // bzip2
        .bytes([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]), // xz
        .bytes([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]), // 7z
        .ascii("Rar!\u{1A}\u{07}"), // RAR

        // Executables
        .bytes([0xCF, 0xFA, 0xED, 0xFE]), // Mach-O 64-bit, little-endian
        .bytes([0xCE, 0xFA, 0xED, 0xFE]), // Mach-O 32-bit, little-endian
        .bytes([0xFE, 0xED, 0xFA, 0xCF]), // Mach-O 64-bit, big-endian
        .bytes([0xFE, 0xED, 0xFA, 0xCE]), // Mach-O 32-bit, big-endian
        .bytes([0xCA, 0xFE, 0xBA, 0xBE]), // Mach-O universal (fat) binary
        .bytes([0xCA, 0xFE, 0xBA, 0xBF]), // Mach-O universal, 64-bit offsets
        .bytes([0xBE, 0xBA, 0xFE, 0xCA]), // Mach-O universal, byte-swapped
        .bytes([0x7F, 0x45, 0x4C, 0x46]), // ELF

        // Databases and media
        .ascii("SQLite format 3\u{00}"),
        .ascii("ID3"), // MP3 with an ID3 tag
        .ascii("ftyp", at: 4), // MP4 / MOV / HEIF and friends
        .ascii("OggS"),
        .ascii("fLaC"),
    ]

    /// True when `data` starts with a known binary container's signature.
    /// Only the caller's already-bounded sample is inspected — no URL or file
    /// handle is involved, so this can never widen a read.
    public static func looksBinary(_ data: Data) -> Bool {
        self.signatures.contains { self.matches($0, in: data) }
    }

    private static func matches(_ signature: Signature, in data: Data) -> Bool {
        guard self.hasBytes(signature.bytes, at: signature.offset, in: data) else { return false }
        guard let trailing = signature.trailing else { return true }
        return self.hasBytes(trailing.bytes, at: trailing.offset, in: data)
    }

    private static func hasBytes(_ bytes: [UInt8], at offset: Int, in data: Data) -> Bool {
        // `data` may be a slice, so index through its own start rather than 0.
        guard data.count >= offset + bytes.count else { return false }
        let start = data.startIndex + offset
        return data[start ..< (start + bytes.count)].elementsEqual(bytes)
    }
}
