import Foundation

/// A user-defined launcher shortcut: a keyword that opens (or searches) a URL
/// template. Parsed from the `Defaults[.launcherQuicklinks]` text box (one per
/// line), edited in Settings → General.
public struct Quicklink: Sendable, Equatable {
    public enum Input: Sendable, Equatable {
        case query(String?)
        case clipboard(String)
    }

    public enum DestinationKind: Sendable, Equatable {
        case web
        case application
    }

    public struct Destination: Sendable, Equatable {
        public let url: URL
        public let kind: DestinationKind
    }

    public let keyword: String
    public let name: String
    public let template: String

    public init(keyword: String, name: String, template: String) {
        self.keyword = keyword
        self.name = name
        self.template = template
    }

    /// The URL to open for `query`. `{query}` in the template is replaced by
    /// the percent-encoded query; a nil query (the keyword typed alone)
    /// strips the placeholder instead.
    public func url(for query: String?) -> URL? {
        self.destination(for: .query(query))?.url
    }

    public func destination(for input: Input) -> Destination? {
        guard Self.validationIssues(for: self.template).isEmpty else { return nil }
        let query: String
        let clipboard: String
        switch input {
        case let .query(value):
            guard !self.template.contains("{clipboard}") else { return nil }
            query = value ?? ""
            clipboard = ""
        case let .clipboard(value):
            query = value
            clipboard = value
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: allowed),
              let encodedClipboard = clipboard.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: self.template
                  .replacingOccurrences(of: "{query}", with: encodedQuery)
                  .replacingOccurrences(of: "{clipboard}", with: encodedClipboard)),
              let scheme = url.scheme?.lowercased()
        else { return nil }
        return Destination(url: url, kind: ["https", "http"].contains(scheme) ? .web : .application)
    }

    public static func validationIssues(for template: String) -> [String] {
        let stripped = template.replacingOccurrences(of: "{query}", with: "sample")
            .replacingOccurrences(of: "{clipboard}", with: "sample")
        guard !stripped.contains("{"), !stripped.contains("}") else {
            return ["Only {query} and {clipboard} placeholders are supported; braces must be balanced."]
        }
        guard !stripped.contains(where: \.isWhitespace),
              let url = URL(string: stripped), let scheme = url.scheme?.lowercased()
        else { return ["Enter an absolute URL with a scheme."] }
        guard !["javascript", "data", "file", "about", "vbscript"].contains(scheme) else {
            return ["This URL scheme cannot be used as a quicklink destination."]
        }
        if ["https", "http"].contains(scheme), url.host?.isEmpty != false {
            return ["Web destinations require a hostname."]
        }
        let authority = template.components(separatedBy: "://").dropFirst().first?
            .split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: { "/?#".contains($0) }).first
        let schemeHasPlaceholder = template.split(separator: ":", maxSplits: 1).first?.contains("{") == true
        if authority?.contains("{") == true || schemeHasPlaceholder {
            return ["Placeholders belong in the destination path, query, or fragment, not its scheme or hostname."]
        }
        return []
    }

    public static func serialize(_ links: [Quicklink]) -> String {
        links.map { "\($0.keyword) = \($0.name) | \($0.template)" }.joined(separator: "\n")
    }

    /// Parses the Settings text box, one quicklink per line:
    /// `keyword = https://example.com/search?q={query}` or
    /// `keyword = Name | https://example.com/search?q={query}`. `#`-prefixed
    /// lines are comments, blank/malformed lines are skipped, and a later
    /// duplicate keyword wins — the same parsing shape as
    /// `AppMatcher.parseAliases`. A name-less line defaults its name to the
    /// template URL's host, minus a leading "www.".
    public static func parse(_ raw: String) -> [Quicklink] {
        var byKeyword: [String: Quicklink] = [:]
        var keywordOrder: [String] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            guard let link = self.parseLine(line) else { continue }
            if byKeyword[link.keyword] == nil {
                keywordOrder.append(link.keyword)
            }
            byKeyword[link.keyword] = link
        }
        return keywordOrder.compactMap { byKeyword[$0] }
    }

    private static func parseLine(_ line: some StringProtocol) -> Quicklink? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let separator = trimmed.firstIndex(of: "=") else { return nil }
        let keyword = AppMatcher.fold(trimmed[..<separator].trimmingCharacters(in: .whitespaces))
        let rest = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty, !rest.isEmpty else { return nil }
        let (name, template) = self.parseNameAndTemplate(rest)
        return Quicklink(keyword: keyword, name: name, template: template)
    }

    private static func parseNameAndTemplate(_ rest: String) -> (name: String, template: String) {
        guard let pipe = rest.firstIndex(of: "|") else {
            return (self.defaultName(for: rest), rest)
        }
        let name = rest[..<pipe].trimmingCharacters(in: .whitespaces)
        let template = rest[rest.index(after: pipe)...].trimmingCharacters(in: .whitespaces)
        return (name.isEmpty ? self.defaultName(for: template) : name, template)
    }

    private static func defaultName(for template: String) -> String {
        guard let host = URL(string: template)?.host else { return template }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
