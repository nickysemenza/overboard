import Foundation

/// JSON coding shared by everything that serializes clips: the CLI's `--json`
/// projection and the archive writer below. Only the *settings* are shared —
/// the two shapes deliberately differ (the CLI emits an actionable projection
/// that never carries payloads; an archive has to be lossless) — but they agree
/// on ISO8601 dates and sorted keys, so both are stable and diff cleanly.
public enum ClipJSONCoding {
    /// The CLI's `--json`: pretty-printed and sorted, so terminal output reads
    /// well and diffs cleanly.
    public static func cliEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// The archive's NDJSON: compact (one record per line) and
    /// millisecond-precise. The store keeps millisecond timestamps and orders
    /// history by them, so rounding to the second on the way out would silently
    /// reshuffle a restored library.
    public static func archiveEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.fractionalISO8601.format(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func archiveDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            return try Self.fractionalISO8601.parse(string)
        }
        return decoder
    }

    /// `Foundation`'s built-in `.iso8601` strategies are whole-second only and
    /// there's no fractional variant to select; this format style is the
    /// millisecond-preserving equivalent — and, unlike `ISO8601DateFormatter`,
    /// `Sendable`, so it can be a shared static.
    private static let fractionalISO8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

// MARK: - On-disk shape

/// Versioned whole-library archives contain streaming clip and snippet NDJSON,
/// content-addressed blobs, optional typed app settings and a checksum manifest.
/// Versioned imports validate everything before changing the database. Archives
/// without a manifest retain the original malformed-line salvage behavior.
public enum ClipArchive {
    public static let itemsFileName = "items.ndjson"
    public static let blobsDirectoryName = "blobs"
    public static let manifestFileName = "manifest.json"
    public static let snippetsFileName = "snippets.ndjson"
    public static let settingsFileName = "settings.json"
    public static let version = 2

    public struct Limits: Sendable {
        public var archiveBytes: Int
        public var lineBytes: Int
        public var blobBytes: Int
        public var records: Int
        public var representations: Int

        public init(
            archiveBytes: Int = 4 * 1024 * 1024 * 1024,
            lineBytes: Int = 4 * 1024 * 1024,
            blobBytes: Int = 512 * 1024 * 1024,
            records: Int = 100_000,
            representations: Int = 1_000_000
        ) {
            self.archiveBytes = archiveBytes
            self.lineBytes = lineBytes
            self.blobBytes = blobBytes
            self.records = records
            self.representations = representations
        }
    }

    public enum SettingValue: Codable, Sendable, Equatable {
        case boolean(Bool)
        case integer(Int)
        case string(String)
        case strings([String])
        case counts([String: Int])
        case timestamps([String: Double])
    }

    public struct Hotkey: Codable, Sendable, Equatable {
        public var keyCode: Int?
        public var modifiers: Int

        public init(keyCode: Int?, modifiers: Int = 0) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }
    }

    public struct Settings: Codable, Sendable, Equatable {
        public var namespace: String
        public var version: Int
        public var values: [String: SettingValue]
        public var hotkeys: [String: Hotkey]

        public init(namespace: String, version: Int, values: [String: SettingValue], hotkeys: [String: Hotkey] = [:]) {
            self.namespace = namespace
            self.version = version
            self.values = values
            self.hotkeys = hotkeys
        }
    }

    struct Manifest: Codable, Sendable {
        var version: Int
        var itemCount: Int
        var snippetCount: Int
        var itemsChecksum: String
        var snippetsChecksum: String
        var settingsChecksum: String?
        var blobs: [String: Int]
    }

    /// One pasteboard flavor of an archived clip. Exactly one of `data`
    /// (inline, base64 via `Data`'s Codable conformance) and `blob` (a hash
    /// into `blobs/`) is set, mirroring how the representation is stored.
    public struct Rep: Codable, Sendable, Equatable {
        public var uti: String
        public var data: Data?
        public var blob: String?
        public var byteSize: Int
        public var itemIndex: Int?
    }

    /// One clip, losslessly. Field names match the CLI's `--json` projection
    /// wherever the two overlap (`preview`, `sourceApp`, `pinned`, …) so a
    /// script that reads one can read the other; the rest are archive-only
    /// columns the CLI deliberately withholds.
    public struct Record: Codable, Sendable, Equatable {
        public var id: String
        public var contentHash: String
        public var kind: String
        public var preview: String?
        /// The FTS-indexed text, carried so an imported row is searchable by
        /// everything the original was — including OCR and AI text folded in
        /// after capture, which re-classifying the payload could not recover.
        public var searchText: String?
        public var sourceApp: String?
        public var sourceBundleID: String?
        public var sourceURL: String?
        public var sourceTitle: String?
        public var byteSize: Int
        public var pinned: Bool
        public var secret: Bool
        public var aiTitle: String?
        public var category: String?
        public var aiSummary: String?
        public var useCount: Int
        public var createdAt: Date
        public var lastUsedAt: Date
        public var updatedAt: Date
        public var charCount: Int?
        public var lineCount: Int?
        public var pixelWidth: Int?
        public var pixelHeight: Int?
        public var fileCount: Int?
        public var linkTitle: String?
        public var linkDescription: String?
        public var faviconData: Data?
        public var previewImageData: Data?
        public var representations: [Rep]
        public var lamport: Int64?

        public init(item: ClipItem, searchText: String?, representations: [Representation]) {
            self.id = item.id
            self.contentHash = item.contentHash
            self.kind = item.kind.rawValue
            self.preview = item.previewText
            self.searchText = searchText
            self.sourceApp = item.sourceAppName
            self.sourceBundleID = item.sourceBundleID
            self.sourceURL = item.sourceURL
            self.sourceTitle = item.sourceTitle
            self.byteSize = item.byteSize
            self.pinned = item.isPinned
            self.secret = item.isSecret
            self.aiTitle = item.aiTitle
            self.category = item.category
            self.aiSummary = item.aiSummary
            self.useCount = item.useCount
            self.createdAt = item.createdAt
            self.lastUsedAt = item.lastUsedAt
            self.updatedAt = item.updatedAt
            self.lamport = item.lamport
            self.charCount = item.charCount
            self.lineCount = item.lineCount
            self.pixelWidth = item.pixelWidth
            self.pixelHeight = item.pixelHeight
            self.fileCount = item.fileCount
            self.linkTitle = item.linkTitle
            self.linkDescription = item.linkDescription
            self.faviconData = item.faviconData
            self.previewImageData = item.previewImageData
            self.representations = representations.map {
                Rep(uti: $0.uti, data: $0.data, blob: $0.blobHash, byteSize: $0.byteSize, itemIndex: $0.itemIndex)
            }
        }

        /// Rebuilds the item this record describes. `id` is the caller's choice
        /// because an archive can be imported into a database that already
        /// holds that primary key (a re-import after the original was purged).
        public func clipItem(id: String) -> ClipItem? {
            guard let kind = ItemKind(rawValue: self.kind) else { return nil }
            return ClipItem(
                id: id,
                contentHash: self.contentHash,
                kind: kind,
                previewText: self.preview,
                sourceBundleID: self.sourceBundleID,
                sourceAppName: self.sourceApp,
                byteSize: self.byteSize,
                isPinned: self.pinned,
                isSecret: self.secret,
                aiTitle: self.aiTitle,
                category: self.category,
                aiSummary: self.aiSummary,
                useCount: self.useCount,
                createdAt: self.createdAt,
                lastUsedAt: self.lastUsedAt,
                updatedAt: self.updatedAt,
                lamport: self.lamport ?? 0,
                charCount: self.charCount,
                lineCount: self.lineCount,
                pixelWidth: self.pixelWidth,
                pixelHeight: self.pixelHeight,
                fileCount: self.fileCount,
                linkTitle: self.linkTitle,
                linkDescription: self.linkDescription,
                faviconData: self.faviconData,
                previewImageData: self.previewImageData,
                sourceURL: self.sourceURL,
                sourceTitle: self.sourceTitle
            )
        }
    }

    public enum Failure: Error, CustomStringConvertible, LocalizedError, Equatable {
        /// The chosen folder holds no `items.ndjson`.
        case notAnArchive(URL)
        case unsafePath(String)
        case invalid(String)
        case checksum(String)
        case limit(String)
        case unsupportedVersion(Int)

        public var errorDescription: String? {
            self.description
        }

        public var description: String {
            switch self {
            case let .notAnArchive(url):
                "No \(ClipArchive.itemsFileName) in \(url.lastPathComponent) — pick a folder written by Export History."
            case let .unsafePath(path):
                "Unsafe archive path: \(path). " + "Symbolic links and non-regular files are not allowed."
            case let .invalid(reason): "Invalid archive: \(reason)."
            case let .checksum(path): "Archive checksum mismatch: \(path)."
            case let .limit(reason): "Archive exceeds the safety limit: \(reason)."
            case let .unsupportedVersion(version):
                "Unsupported archive version \(version). " + "Keep this archive for a newer app."
            }
        }
    }
}

/// What an export wrote.
public struct ExportSummary: Sendable, Equatable {
    public let directory: URL
    public let itemCount: Int
    public let blobCount: Int
    /// Secrets left behind because `includeSecrets` was false. Surfaced so the
    /// UI can say the backup is deliberately incomplete rather than silently
    /// dropping rows.
    public let secretsExcluded: Int
    /// Missing blob-backed payloads remain referenced so a later restore can
    /// repair them. Corrupt or unsafe payloads abort publication instead.
    public let blobsMissing: Int
    public let snippetCount: Int
    public let includesSettings: Bool
}

/// What a validated import restored. Legacy archives can salvage malformed
/// lines; versioned archives reject malformed records before changing the store.
public struct ImportSummary: Sendable, Equatable {
    public var imported: Int
    /// Records whose `contentHash` already matched a live item.
    public var duplicatesSkipped: Int
    /// One message per line that couldn't be read, e.g. "line 7: …".
    public let malformedLines: [String]
    /// Unique blob files absent from the archive. Their representation references
    /// are retained so importing a complete archive later can repair them.
    public let missingBlobs: Int
    public var representationsRepaired: Int = 0
    public var snippetsImported: Int = 0
    public var settings: ClipArchive.Settings?
}
