import Foundation

/// Surfaces clipboard-history hits as launcher rows, reusing the drawer's
/// FTS search (so `kind:` / `app:` / `category:` operators work here too).
public struct ClipSearchProvider: LauncherProvider {
    private let store: ClipStore
    private let limit: Int

    public init(store: ClipStore, limit: Int = 5) {
        self.store = store
        self.limit = limit
    }

    public func results(for query: String) async -> [LauncherResult] {
        guard query.count >= 2 else { return [] }
        // ClipStore.search falls back to a recent() listing when the query
        // produces no FTS match and no filters — fine for the drawer, but the
        // launcher must not dump recent clips on a punctuation-only query.
        let parsed = ParsedQuery.parse(query)
        guard FTSQuery.match(for: parsed.text) != nil || parsed.hasFilters else { return [] }
        // Over-fetch so dropping secrets can't starve the row list.
        guard let items = try? await store.search(query, limit: self.limit * 2) else { return [] }
        return items.filter { !$0.isSecret }.prefix(self.limit).map { .clip($0) }
    }
}
