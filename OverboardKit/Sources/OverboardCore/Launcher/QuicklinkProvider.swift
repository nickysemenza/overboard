import Foundation

/// User-defined launcher shortcuts (Settings → General → Quicklinks). The
/// first whitespace-separated token of the query is matched against a
/// `Quicklink.keyword`; anything after it becomes the query passed to
/// `Quicklink.url(for:)`.
public struct QuicklinkProvider: LauncherProvider {
    private let links: @Sendable () -> [Quicklink]

    public var searchScopes: Set<LauncherScope> {
        [.all]
    }

    public init(links: @escaping @Sendable () -> [Quicklink]) {
        self.links = links
    }

    public func results(for query: String) async -> [LauncherResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let keywordRange = trimmed.rangeOfCharacter(from: .whitespaces)
        let keyword = AppMatcher.fold(keywordRange.map { String(trimmed[..<$0.lowerBound]) } ?? trimmed)
        let rest = keywordRange.map { trimmed[$0.upperBound...].trimmingCharacters(in: .whitespaces) } ?? ""
        guard let link = self.links().first(where: { $0.keyword == keyword }) else { return [] }
        guard let url = link.url(for: rest.isEmpty ? nil : rest) else { return [] }
        return [.quicklink(link, query: rest, url: url)]
    }
}
