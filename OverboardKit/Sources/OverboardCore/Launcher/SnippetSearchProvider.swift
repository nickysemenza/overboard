import Foundation

/// Surfaces saved snippets as launcher rows. The store's substring search
/// (same as the drawer's ⌘/ picker) recalls candidates; ranking puts
/// title-prefix hits above title-substring above body-only matches.
public struct SnippetSearchProvider: LauncherProvider {
    private let store: ClipStore
    private let limit: Int

    public init(store: ClipStore, limit: Int = 3) {
        self.store = store
        self.limit = limit
    }

    public func results(for query: String) async -> [LauncherResult] {
        // searchSnippets("") returns the full list; require a real query.
        guard query.count >= 2 else { return [] }
        guard let snippets = try? await store.searchSnippets(query) else { return [] }
        return snippets
            .enumerated()
            .map { index, snippet in
                (rank: Self.rank(snippet, query: query), index: index, snippet: snippet)
            }
            // Index tiebreaker keeps the store's title order within a tier.
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .prefix(self.limit)
            .map { .snippet($0.snippet) }
    }

    /// 0 = title prefix, 1 = title word prefix, 2 = title substring,
    /// 3 = body-only match (the store already guaranteed *some* match).
    static func rank(_ snippet: Snippet, query: String) -> Int {
        let title = snippet.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let query = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if title.hasPrefix(query) { return 0 }
        let words = title.split { !$0.isLetter && !$0.isNumber }
        if words.contains(where: { $0.hasPrefix(query) }) { return 1 }
        if title.contains(query) { return 2 }
        return 3
    }
}
