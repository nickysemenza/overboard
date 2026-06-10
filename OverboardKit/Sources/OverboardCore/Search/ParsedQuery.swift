import Foundation

/// Splits a raw drawer query into free text plus filter operators:
/// `kind:image`, `app:safari`, `category:code`. Unrecognized operators fall
/// through as plain search text.
public struct ParsedQuery: Equatable, Sendable {
    public var text: String
    public var kind: ItemKind?
    /// Case-insensitive substring match against source app name or bundle ID.
    public var app: String?
    public var category: String?

    public var hasFilters: Bool {
        self.kind != nil || self.app != nil || self.category != nil
    }

    private static let kindAliases: [String: ItemKind] = [
        "text": .text,
        "link": .link, "url": .link, "links": .link,
        "image": .image, "img": .image, "picture": .image, "screenshot": .image,
        "file": .file, "files": .file,
        "color": .color,
    ]

    public static func parse(_ raw: String) -> ParsedQuery {
        var result = ParsedQuery(text: "")
        var textTokens: [String] = []

        for token in raw.split(whereSeparator: \.isWhitespace) {
            let lower = token.lowercased()
            if lower.hasPrefix("kind:"), let kind = kindAliases[String(lower.dropFirst(5))] {
                result.kind = kind
            } else if lower.hasPrefix("app:"), token.count > 4 {
                result.app = String(token.dropFirst(4))
            } else if lower.hasPrefix("category:"), token.count > 9 {
                result.category = String(lower.dropFirst(9))
            } else {
                textTokens.append(String(token))
            }
        }
        result.text = textTokens.joined(separator: " ")
        return result
    }

    /// In-memory check, used to keep semantic-search extras consistent with
    /// the SQL filters.
    public func matches(_ item: ClipItem) -> Bool {
        if let kind, item.kind != kind { return false }
        if let app {
            let needle = app.lowercased()
            let nameHit = item.sourceAppName?.lowercased().contains(needle) ?? false
            let bundleHit = item.sourceBundleID?.lowercased().contains(needle) ?? false
            if !nameHit, !bundleHit { return false }
        }
        if let category, item.category != category { return false }
        return true
    }
}
