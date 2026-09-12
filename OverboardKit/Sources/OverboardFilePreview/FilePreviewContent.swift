import FileType
import Foundation
import UniformTypeIdentifiers

/// The deliberately narrow, text-only contract shared by Overboard and its
/// Quick Look extension. Rich/vendor document formats stay with their owners.
public nonisolated enum FilePreviewEligibility {
    public static let sourceExtensions: Set<String> = [
        "c", "cc", "cpp", "cxx", "h", "hpp", "m", "mm", "swift", "java", "kt",
        "go", "rs", "py", "rb", "php", "pl", "lua", "r", "js", "jsx", "ts", "tsx",
        "vue", "svelte", "dart", "cs", "fs", "fsx", "scala", "ex", "exs", "erl", "hrl",
        "hs", "clj", "cljs", "sh", "bash", "zsh", "fish", "ps1", "sql",
    ]
    public static let configurationExtensions: Set<String> = [
        "yaml", "yml", "json", "jsonc", "toml", "ini", "cfg", "conf", "properties",
        "env", "editorconfig", "xcconfig", "plist", "xml", "gradle", "makefile", "cmake",
        "dockerfile", "gitignore", "gitattributes", "gitmodules",
    ]
    public static let markupExtensions: Set<String> = ["md", "markdown", "mdown", "mkdn", "rst", "html", "htm", "xhtml", "css", "scss", "sass", "less"]
    public static let textExtensions: Set<String> = ["txt", "text", "log", "csv", "tsv"]

    public static let supportedExtensions = sourceExtensions
        .union(configurationExtensions)
        .union(markupExtensions)
        .union(textExtensions)

    public static func supports(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if self.supportedExtensions.contains(ext) || self.configurationExtensions.contains(name) {
            return true
        }
        return self.supportsInferredPlainTextType(UTType(filenameExtension: ext)?.identifier)
    }

    public static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown", "mdown", "mkdn"].contains(url.pathExtension.lowercased())
    }

    /// Keeps the dynamic path intentionally narrower than `public.text`: rich
    /// text (such as RTF) retains its system/vendor preview.
    static func supportsInferredPlainTextType(_ identifier: String?) -> Bool {
        guard let identifier, let type = UTType(identifier) else { return false }
        return type.conforms(to: .plainText)
    }
}

public nonisolated struct FilePreviewContent: Sendable, Equatable {
    public static let maximumReadBytes = 256 * 1024
    public static let maximumDisplayedCharacters = 12000

    public let url: URL
    public let text: String
    public let language: String?
    public let isMarkdown: Bool
    public let isTruncated: Bool
    public let fileSize: Int64?

    public init(url: URL, text: String, language: String?, isMarkdown: Bool, isTruncated: Bool, fileSize: Int64?) {
        self.url = url
        self.text = text
        self.language = language
        self.isMarkdown = isMarkdown
        self.isTruncated = isTruncated
        self.fileSize = fileSize
    }
}

public nonisolated enum FilePreviewLoadError: LocalizedError, Equatable, Sendable {
    case unsupported
    case unreadable
    case binary

    public var errorDescription: String? {
        switch self {
        case .unsupported: "This file type uses its normal Quick Look preview."
        case .unreadable: "This text file couldn’t be read."
        case .binary: "This file isn’t readable text."
        }
    }
}

public nonisolated enum FilePreviewLoader {
    public static func load(_ url: URL) throws -> FilePreviewContent {
        guard FilePreviewEligibility.supports(url) else { throw FilePreviewLoadError.unsupported }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let size = values?.fileSize.map(Int64.init)
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw FilePreviewLoadError.unreadable }
        defer { try? handle.close() }

        let data: Data
        do {
            data = try handle.read(upToCount: FilePreviewContent.maximumReadBytes + 1) ?? Data()
        } catch {
            throw FilePreviewLoadError.unreadable
        }
        let readWasCapped = data.count > FilePreviewContent.maximumReadBytes
        let bounded = readWasCapped ? data.prefix(FilePreviewContent.maximumReadBytes) : data
        let previewData = Data(bounded)
        guard !self.isKnownBinary(previewData), let decoded = self.decode(previewData) else { throw FilePreviewLoadError.binary }
        guard !decoded.unicodeScalars.contains(where: { $0.value == 0 || ($0.value < 8 && $0.value != 9 && $0.value != 10 && $0.value != 13) }) else {
            throw FilePreviewLoadError.binary
        }
        let characterCapped = decoded.count > FilePreviewContent.maximumDisplayedCharacters
        let text = String(decoded.prefix(FilePreviewContent.maximumDisplayedCharacters))
        return FilePreviewContent(
            url: url,
            text: text,
            language: self.language(for: url),
            isMarkdown: FilePreviewEligibility.isMarkdown(url),
            isTruncated: readWasCapped || characterCapped,
            fileSize: size
        )
    }

    private static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data, encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16BigEndian) }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        let bytes = [UInt8](data.prefix(128))
        let evenNulls = stride(from: 0, to: bytes.count, by: 2).count(where: { bytes[$0] == 0 })
        let oddNulls = stride(from: 1, to: bytes.count, by: 2).count(where: { bytes[$0] == 0 })
        if oddNulls > bytes.count / 8 { return String(data: data, encoding: .utf16LittleEndian) }
        if evenNulls > bytes.count / 8 { return String(data: data, encoding: .utf16BigEndian) }
        return nil
    }

    /// FileType only sees our already-bounded sample; it never receives a URL
    /// or file handle, so archive/container inspection cannot expand the read.
    private static func isKnownBinary(_ data: Data) -> Bool {
        guard let detected = FileType.detect(in: data) else { return false }
        return detected.mimeGroup != .text
    }

    private static func language(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "swift": "swift"
        case "py": "python"
        case "rb": "ruby"
        case "rs": "rust"
        case "js", "jsx": "javascript"
        case "ts", "tsx": "typescript"
        case "json", "jsonc": "json"
        case "yaml", "yml": "yaml"
        case "toml": "toml"
        case "xml", "plist": "xml"
        case "html", "htm", "xhtml": "html"
        case "css", "scss", "sass", "less": "css"
        case "sh", "bash", "zsh", "fish": "bash"
        case "sql": "sql"
        case "c", "h", "cc", "cpp", "cxx", "hpp": "cpp"
        default: nil
        }
    }
}
