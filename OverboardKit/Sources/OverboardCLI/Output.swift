import Foundation
import OverboardCore

/// The stable JSON shape emitted by `--json`. A deliberate projection of
/// `ClipItem` — only fields a script or agent can act on, never raw payloads
/// and never the secret-only columns (secrets are filtered upstream anyway).
struct ClipJSON: Codable {
    let id: String
    let kind: String
    let preview: String?
    let sourceApp: String?
    let sourceBundleID: String?
    let sourceURL: String?
    let createdAt: Date
    let lastUsedAt: Date
    let pinned: Bool
    let byteSize: Int
    let useCount: Int

    init(_ item: ClipItem) {
        self.id = item.id
        self.kind = item.kind.rawValue
        self.preview = item.previewText
        self.sourceApp = item.sourceAppName
        self.sourceBundleID = item.sourceBundleID
        self.sourceURL = item.sourceURL
        self.createdAt = item.createdAt
        self.lastUsedAt = item.lastUsedAt
        self.pinned = item.isPinned
        self.byteSize = item.byteSize
        self.useCount = item.useCount
    }
}

enum Output {
    /// The single gate that keeps secrets off every code path. Pure and
    /// testable so the guarantee can be pinned by a unit test rather than
    /// re-asserted at each call site.
    static func visible(_ items: [ClipItem]) -> [ClipItem] {
        items.filter { !$0.isSecret }
    }

    /// One human line per clip: `N. [kind] preview — appName · relative-age`.
    /// `N` is 1-based to match `get N`. Missing app or preview segments are
    /// dropped rather than rendered blank.
    static func textLine(index: Int, item: ClipItem, now: Date = Date()) -> String {
        var line = "\(index). [\(item.kind.rawValue)]"
        if let preview = item.previewText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preview.isEmpty
        {
            // Collapse to a single line so multi-line clips stay one row.
            line += " " + preview.replacingOccurrences(of: "\n", with: " ")
        }
        var suffix: [String] = []
        if let app = item.sourceAppName, !app.isEmpty { suffix.append(app) }
        suffix.append(self.relativeAge(from: item.lastUsedAt, to: now))
        line += " — " + suffix.joined(separator: " · ")
        return line
    }

    /// The full text listing for `history` / `search`.
    static func textList(_ items: [ClipItem], now: Date = Date()) -> String {
        items.enumerated()
            .map { self.textLine(index: $0.offset + 1, item: $0.element, now: now) }
            .joined(separator: "\n")
    }

    static func relativeAge(from date: Date, to now: Date) -> String {
        // Built per call: RelativeDateTimeFormatter isn't Sendable, so it can't
        // be a shared static under Swift 6 concurrency. Cheap in a short-lived
        // CLI that formats a screenful of rows at most.
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// Shared encoder: ISO8601 dates, sorted keys, pretty-printed — stable
    /// output that diffs cleanly and reads well in a terminal.
    static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func jsonArray(_ items: [ClipItem]) throws -> String {
        let payload = items.map(ClipJSON.init)
        let data = try self.jsonEncoder().encode(payload)
        // JSONEncoder output is always valid UTF-8; the fallback never fires.
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func jsonObject(_ item: ClipItem) throws -> String {
        let data = try self.jsonEncoder().encode(ClipJSON(item))
        return String(data: data, encoding: .utf8) ?? ""
    }
}
