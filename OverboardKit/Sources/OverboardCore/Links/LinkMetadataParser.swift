import Foundation

/// Pure HTML metadata extraction — no networking, no I/O. Pulls the fields a
/// rich link card needs out of a page's `<head>`: title, description, favicon,
/// and preview image. Open Graph tags win over their plain-HTML equivalents.
///
/// The parsing is deliberately regex/scan-based rather than a full HTML parse:
/// we only ever look at head-level `<title>`, `<meta>`, and `<link>` tags, and
/// a lenient scan tolerates the malformed markup real pages ship far better
/// than a strict tree parser would.
public enum LinkMetadataParser {
    public struct Result: Equatable {
        public var title: String?
        public var description: String?
        public var faviconURL: URL?
        public var previewImageURL: URL?
    }

    public static func parse(html: String, baseURL: URL) -> Result {
        let ogTitle = self.metaContent(in: html, property: "og:title")
        let bareTitle = self.titleTag(in: html)
        let title = ogTitle ?? bareTitle

        let description = self.metaContent(in: html, property: "og:description")
            ?? self.metaContent(in: html, name: "description")

        let previewImageURL = self.metaContent(in: html, property: "og:image")
            .flatMap { self.resolve($0, against: baseURL) }

        let faviconURL = self.iconHref(in: html)
            .flatMap { self.resolve($0, against: baseURL) }

        return Result(
            title: title,
            description: description,
            faviconURL: faviconURL,
            previewImageURL: previewImageURL
        )
    }

    // MARK: - Tag extraction

    /// The text inside the first `<title>…</title>`, entity-decoded and
    /// whitespace-collapsed. Nil if absent or empty.
    private static func titleTag(in html: String) -> String? {
        guard let open = html.range(
            of: "<title",
            options: [.caseInsensitive]
        ),
            let gt = html.range(of: ">", range: open.upperBound ..< html.endIndex),
            let close = html.range(
                of: "</title",
                options: [.caseInsensitive],
                range: gt.upperBound ..< html.endIndex
            )
        else { return nil }
        let raw = String(html[gt.upperBound ..< close.lowerBound])
        return self.clean(raw)
    }

    /// `content` of a `<meta property="…">` tag (Open Graph style).
    private static func metaContent(in html: String, property: String) -> String? {
        self.metaContent(in: html, attribute: "property", value: property)
    }

    /// `content` of a `<meta name="…">` tag (plain HTML style).
    private static func metaContent(in html: String, name: String) -> String? {
        self.metaContent(in: html, attribute: "name", value: name)
    }

    /// Scans every `<meta …>` tag and returns the `content` of the first whose
    /// `attribute` equals `value` (case-insensitive). Attribute order within
    /// the tag is irrelevant; `content` may appear before or after the key.
    private static func metaContent(in html: String, attribute: String, value: String) -> String? {
        for tag in self.tags(named: "meta", in: html) {
            guard let key = self.attribute(attribute, in: tag),
                  key.caseInsensitiveCompare(value) == .orderedSame,
                  let content = self.attribute("content", in: tag),
                  !content.isEmpty
            else { continue }
            return self.clean(content)
        }
        return nil
    }

    /// `href` of the first `<link>` whose `rel` contains "icon" (matches
    /// "icon", "shortcut icon", "apple-touch-icon", …).
    private static func iconHref(in html: String) -> String? {
        for tag in self.tags(named: "link", in: html) {
            guard let rel = self.attribute("rel", in: tag),
                  rel.range(of: "icon", options: .caseInsensitive) != nil,
                  let href = self.attribute("href", in: tag),
                  !href.isEmpty
            else { continue }
            return self.decodeEntities(in: href)
        }
        return nil
    }

    // MARK: - Low-level scanning

    /// Every `<name …>` open tag body (the text between `<name` and the closing
    /// `>`), for each occurrence in the document. Case-insensitive on the name.
    private static func tags(named name: String, in html: String) -> [Substring] {
        var results: [Substring] = []
        var searchStart = html.startIndex
        let opener = "<\(name)"
        while let open = html.range(
            of: opener,
            options: [.caseInsensitive],
            range: searchStart ..< html.endIndex
        ) {
            // The char right after the name must be whitespace, `>` or `/` so
            // "<link" doesn't match "<linkfoo".
            let after = open.upperBound
            if after < html.endIndex {
                let c = html[after]
                if !(c.isWhitespace || c == ">" || c == "/") {
                    searchStart = after
                    continue
                }
            }
            guard let close = html.range(of: ">", range: after ..< html.endIndex) else { break }
            results.append(html[after ..< close.lowerBound])
            searchStart = close.upperBound
        }
        return results
    }

    /// The value of `name=` within a single tag body. Handles single, double,
    /// and unquoted values, in any order, case-insensitive on the attribute
    /// name. Returns the raw (un-decoded) value.
    private static func attribute(_ name: String, in tag: Substring) -> String? {
        let lower = tag.lowercased()
        var searchStart = lower.startIndex
        while let hit = lower.range(of: name.lowercased(), range: searchStart ..< lower.endIndex) {
            // Preceding char must be a boundary (start or whitespace/quote/slash)
            // so `name` doesn't match inside `og:sitename`.
            let precededOK: Bool = {
                guard hit.lowerBound > lower.startIndex else { return true }
                let prev = lower[lower.index(before: hit.lowerBound)]
                return prev.isWhitespace || prev == "\"" || prev == "'" || prev == "/"
            }()
            // Next non-space char must be `=`.
            var cursor = hit.upperBound
            while cursor < lower.endIndex, lower[cursor].isWhitespace {
                cursor = lower.index(after: cursor)
            }
            guard precededOK, cursor < lower.endIndex, lower[cursor] == "=" else {
                searchStart = hit.upperBound
                continue
            }
            // Move past `=` and any whitespace, then read the value against the
            // ORIGINAL-cased tag (offsets align: lowercasing is 1:1 here).
            var valueStart = lower.index(after: cursor)
            while valueStart < lower.endIndex, lower[valueStart].isWhitespace {
                valueStart = lower.index(after: valueStart)
            }
            guard valueStart < lower.endIndex else { return nil }
            let offset = lower.distance(from: lower.startIndex, to: valueStart)
            let origStart = tag.index(tag.startIndex, offsetBy: offset)
            let first = tag[origStart]
            if first == "\"" || first == "'" {
                let quote = first
                let contentStart = tag.index(after: origStart)
                guard let end = tag[contentStart...].firstIndex(of: quote) else { return nil }
                return String(tag[contentStart ..< end])
            } else {
                // Unquoted: value runs to the next whitespace or tag end.
                let end = tag[origStart...].firstIndex { $0.isWhitespace } ?? tag.endIndex
                return String(tag[origStart ..< end])
            }
        }
        return nil
    }

    // MARK: - URL + text cleanup

    private static func resolve(_ href: String, against baseURL: URL) -> URL? {
        let decoded = self.decodeEntities(in: href).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty else { return nil }
        return URL(string: decoded, relativeTo: baseURL)?.absoluteURL
    }

    /// Entity-decode then collapse runs of whitespace, trimming the result.
    private static func clean(_ raw: String) -> String? {
        let decoded = self.decodeEntities(in: raw)
        let collapsed = decoded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Decodes the handful of HTML entities that show up in titles and URLs:
    /// the named essentials plus decimal and hex numeric references.
    static func decodeEntities(in text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&",
                  let semi = text[index...].firstIndex(of: ";"),
                  text.distance(from: index, to: semi) <= 10
            else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }
            let entity = text[text.index(after: index) ..< semi]
            if let decoded = self.decode(entity: entity) {
                result.append(decoded)
                index = text.index(after: semi)
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }

    private static func decode(entity: Substring) -> Character? {
        switch entity {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "#39": return "'"
        case "#x27", "#X27": return "'"
        default: break
        }
        guard entity.first == "#" else { return nil }
        let body = entity.dropFirst()
        let scalar: UInt32? = if let f = body.first, f == "x" || f == "X" {
            UInt32(body.dropFirst(), radix: 16)
        } else {
            UInt32(body, radix: 10)
        }
        guard let scalar, let unicode = Unicode.Scalar(scalar) else { return nil }
        return Character(unicode)
    }
}
