import CryptoKit
import Foundation
import ImageIO

/// Pure functions that turn a `PasteboardSnapshot` into the derived fields a
/// `ClipItem` needs. No I/O — fully unit-testable.
public enum CaptureClassifier {
    public struct Classified: Sendable, Equatable {
        public var kind: ItemKind
        public var contentHash: String
        public var previewText: String?
        public var searchText: String?
        public var byteSize: Int
        public var isSecret: Bool = false
        /// Card-footer metadata, derived from the full payload at capture time.
        public var charCount: Int?
        public var lineCount: Int?
        public var pixelWidth: Int?
        public var pixelHeight: Int?
        public var fileCount: Int?
    }

    static let previewLimit = 500
    static let searchTextLimit = 20000

    /// Returns nil for snapshots not worth keeping (no reps, or whitespace-only text).
    public static func classify(_ snapshot: PasteboardSnapshot) -> Classified? {
        guard !snapshot.reps.isEmpty else { return nil }

        let byUTI = Dictionary(
            snapshot.reps.map { ($0.uti, $0.data) },
            uniquingKeysWith: { first, _ in first }
        )
        let plainText = byUTI[WellKnownUTI.plainText].flatMap { String(data: $0, encoding: .utf8) }
        let kind = kind(byUTI: byUTI, plainText: plainText)

        if kind == .text || kind == .link {
            guard let text = plainText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
        }

        guard let primary = primaryData(for: kind, byUTI: byUTI) else { return nil }
        let totalBytes = snapshot.reps.reduce(0) { $0 + $1.data.count }

        // Secrets keep their payload (paste still works) but get a masked
        // preview and are never indexed for search. The retained payload is
        // stored in cleartext for its TTL — bounded by the 0700 store directory
        // and the short expiry sweep, not encrypted at rest.
        //
        // Two sources: a secret pattern anywhere in copied text, or a `.link`
        // whose URL carries a credential/token (presigned S3, magic-login, OAuth
        // fragment). Flagging the link secret also keeps it off the network — the
        // fetch paths skip `isSecret` items — so a single-use link isn't consumed.
        if kind == .text, let text = plainText, let secret = SecretDetector.detect(in: text) {
            return self.secretClassified(kind: kind, primary: primary, label: secret.label, bytes: totalBytes)
        }
        if kind == .link, let text = plainText,
           let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           URLSensitivity.isSensitive(url)
        {
            return self.secretClassified(kind: kind, primary: primary, label: "Link with credentials", bytes: totalBytes)
        }

        // Compute the image size once and reuse it for both the preview string
        // and the footer metadata, rather than parsing it back out of the text.
        let pixelSize: (width: Int, height: Int)? = kind == .image
            ? (byUTI[WellKnownUTI.png] ?? byUTI[WellKnownUTI.tiff]).flatMap(self.imagePixelSize)
            : nil

        // Counts come from the full plainText, not the truncated preview.
        var charCount: Int?
        var lineCount: Int?
        if kind == .text || kind == .link, let text = plainText {
            charCount = text.count
            lineCount = text.lineCount
        }

        return Classified(
            kind: kind,
            contentHash: self.hash(kind: kind, primary: primary),
            previewText: self.previewText(for: kind, pixelSize: pixelSize, byUTI: byUTI, plainText: plainText),
            searchText: self.searchText(for: kind, byUTI: byUTI, plainText: plainText),
            byteSize: totalBytes,
            charCount: charCount,
            lineCount: lineCount,
            pixelWidth: pixelSize?.width,
            pixelHeight: pixelSize?.height,
            fileCount: kind == .file ? self.fileNames(byUTI: byUTI)?.count : nil
        )
    }

    private static func secretClassified(
        kind: ItemKind, primary: Data, label: String, bytes: Int
    ) -> Classified {
        Classified(
            kind: kind,
            contentHash: self.hash(kind: kind, primary: primary),
            previewText: "Secret — \(label)",
            searchText: nil,
            byteSize: bytes,
            isSecret: true
        )
    }

    // MARK: - Kind

    private static func kind(byUTI: [String: Data], plainText: String?) -> ItemKind {
        if byUTI[WellKnownUTI.fileURLs] != nil { return .file }
        if byUTI[WellKnownUTI.color] != nil { return .color }
        if byUTI[WellKnownUTI.png] != nil || byUTI[WellKnownUTI.tiff] != nil { return .image }
        if let text = plainText, isSingleURL(text) { return .link }
        return .text
    }

    static func isSingleURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil
        else { return false }
        return true
    }

    // MARK: - Hash

    /// The content hash is computed over the kind plus the "primary"
    /// representation only, so the same text copied from two apps (which may
    /// attach different RTF/HTML flavors) still dedupes.
    private static func primaryData(for kind: ItemKind, byUTI: [String: Data]) -> Data? {
        switch kind {
        case .text, .link:
            byUTI[WellKnownUTI.plainText]
        case .image:
            byUTI[WellKnownUTI.png] ?? byUTI[WellKnownUTI.tiff]
        case .file:
            byUTI[WellKnownUTI.fileURLs]
        case .color:
            byUTI[WellKnownUTI.color]
        }
    }

    private static func hash(kind: ItemKind, primary: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data((kind.rawValue + ":").utf8))
        hasher.update(data: primary)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Preview & search text

    private static func previewText(
        for kind: ItemKind, pixelSize: (width: Int, height: Int)?,
        byUTI: [String: Data], plainText: String?
    ) -> String? {
        switch kind {
        case .text, .link:
            guard let text = plainText else { return nil }
            return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(self.previewLimit))
        case .image:
            if let pixelSize {
                return "Image \(pixelSize.width)×\(pixelSize.height)"
            }
            return "Image"
        case .file:
            guard let names = fileNames(byUTI: byUTI) else { return "File" }
            return names.joined(separator: ", ")
        case .color:
            return "Color"
        }
    }

    private static func searchText(
        for kind: ItemKind, byUTI: [String: Data], plainText: String?
    ) -> String? {
        switch kind {
        case .text, .link:
            guard let text = plainText else { return nil }
            return String(text.prefix(self.searchTextLimit))
        case .file:
            return self.fileNames(byUTI: byUTI)?.joined(separator: " ")
        case .image, .color:
            return nil
        }
    }

    static func fileNames(byUTI: [String: Data]) -> [String]? {
        guard let data = byUTI[WellKnownUTI.fileURLs],
              let strings = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        let names = strings.compactMap { URL(string: $0)?.lastPathComponent }
        return names.isEmpty ? nil : names
    }

    static func imagePixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}
