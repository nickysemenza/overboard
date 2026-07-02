import Foundation
import GRDB

public struct ClipItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var contentHash: String
    public var kind: ItemKind
    public var previewText: String?
    public var sourceBundleID: String?
    public var sourceAppName: String?
    public var byteSize: Int
    public var isPinned: Bool
    public var isSecret: Bool
    /// LLM-generated short title (background enrichment; nil until generated).
    public var aiTitle: String?
    /// LLM-assigned category (code, error, address, contact, prose, list, other).
    public var category: String?
    /// LLM one-sentence summary; only stored for long clips (≥250 chars).
    public var aiSummary: String?
    public var useCount: Int
    public var createdAt: Date
    public var lastUsedAt: Date
    public var updatedAt: Date
    public var lamport: Int64
    public var deletedAt: Date?
    /// Card-footer metadata (migration v2); nil for kinds without a footer or
    /// for rows captured before backfill. Codable auto-maps to GRDB columns.
    public var charCount: Int?
    public var lineCount: Int?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var fileCount: Int?
    /// Rich link cards (migration v3); nil for non-link kinds and for links
    /// captured before backfill. `linkTitle == ""` is the failed-fetch sentinel:
    /// a fetch was attempted and yielded no usable title, so backfill won't retry.
    public var linkTitle: String?
    public var linkDescription: String?
    public var faviconData: Data?
    public var previewImageData: Data?

    public init(
        id: String = UUID().uuidString,
        contentHash: String,
        kind: ItemKind,
        previewText: String?,
        sourceBundleID: String?,
        sourceAppName: String?,
        byteSize: Int,
        isPinned: Bool = false,
        isSecret: Bool = false,
        aiTitle: String? = nil,
        category: String? = nil,
        aiSummary: String? = nil,
        useCount: Int = 1,
        createdAt: Date,
        lastUsedAt: Date,
        updatedAt: Date,
        lamport: Int64 = 0,
        deletedAt: Date? = nil,
        charCount: Int? = nil,
        lineCount: Int? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        fileCount: Int? = nil,
        linkTitle: String? = nil,
        linkDescription: String? = nil,
        faviconData: Data? = nil,
        previewImageData: Data? = nil
    ) {
        self.id = id
        self.contentHash = contentHash
        self.kind = kind
        self.previewText = previewText
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.byteSize = byteSize
        self.isPinned = isPinned
        self.isSecret = isSecret
        self.aiTitle = aiTitle
        self.category = category
        self.aiSummary = aiSummary
        self.useCount = useCount
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.updatedAt = updatedAt
        self.lamport = lamport
        self.deletedAt = deletedAt
        self.charCount = charCount
        self.lineCount = lineCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fileCount = fileCount
        self.linkTitle = linkTitle
        self.linkDescription = linkDescription
        self.faviconData = faviconData
        self.previewImageData = previewImageData
    }
}

extension ClipItem: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "item"
}

// MARK: - Card metadata footer

extension ClipItem {
    /// One-line footer summarizing the clip's shape, shown under the card
    /// content. Pure and unit-testable; nil means "render no footer".
    public var metadataFooter: String? {
        guard !self.isSecret else { return nil }
        switch self.kind {
        case .text:
            guard let chars = charCount else { return nil }
            let charsPart = "\(Self.decimal(chars)) \(chars == 1 ? "char" : "chars")"
            guard let lines = lineCount, lines > 1 else { return charsPart }
            return "\(charsPart) · \(lines) lines"
        case .link:
            // The link's host, parsed from the URL preview text.
            return Self.linkHost(fromPreview: self.previewText)
        case .image:
            // Prefer backfilled columns; fall back to the render-time preview
            // parse for rows the migration couldn't reach.
            if let width = pixelWidth, let height = pixelHeight {
                return "\(width) × \(height)"
            }
            guard let size = Self.imageDimensions(fromPreview: previewText) else { return nil }
            return "\(size.width) × \(size.height)"
        case .file:
            guard let count = fileCount else { return nil }
            let filesPart = count == 1 ? "1 file" : "\(count) files"
            return "\(filesPart) · \(Self.byteCount(self.byteSize))"
        case .color:
            return nil
        }
    }

    /// Parses the "Image W×H" preview string produced by
    /// `CaptureClassifier.previewText`. Used to backfill and to render footers
    /// for images captured before migration v2.
    static func imageDimensions(fromPreview preview: String?) -> (width: Int, height: Int)? {
        guard let preview else { return nil }
        let scanner = Scanner(string: preview)
        // Skip up to the first digit ("Image " prefix, tolerant of variants).
        _ = scanner.scanUpToCharacters(from: .decimalDigits)
        guard let width = scanner.scanInt(),
              scanner.scanString("×") != nil,
              let height = scanner.scanInt()
        else { return nil }
        return (width, height)
    }

    /// The display host of a `.link` clip: the URL's host with a leading
    /// "www." stripped. Nil if the preview isn't a parseable URL with a host.
    /// Shared by the footer and the card headline's host line.
    public static func linkHost(fromPreview preview: String?) -> String? {
        guard let preview,
              let host = URL(string: preview.trimmingCharacters(in: .whitespacesAndNewlines))?.host
        else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func decimal(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// Matches the History settings tab's disk-usage formatting (`.file` style).
    private static func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

extension String {
    /// Number of lines, counting the last line even without a trailing newline.
    /// An empty string is zero lines.
    var lineCount: Int {
        guard !isEmpty else { return 0 }
        return reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }
}
