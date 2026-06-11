import Foundation

/// Surfaces saved snippets as launcher rows (substring match on title + body,
/// same as the drawer's ⌘/ picker).
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
        return snippets.prefix(self.limit).map { .snippet($0) }
    }
}
