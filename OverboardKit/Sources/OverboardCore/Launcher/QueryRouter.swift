import Foundation

/// Concatenates provider results in priority order. The view model routes
/// every keystroke through an instant router (calculator + web + apps) that
/// answers from memory, while secondary providers (files, snippets, clipboard)
/// run concurrently alongside it and merge in as they arrive — so the bar
/// never waits on file I/O to show the math.
public struct QueryRouter: Sendable {
    private let providers: [any LauncherProvider]

    public init(providers: [any LauncherProvider]) {
        self.providers = providers
    }

    public func results(for query: String, scope: LauncherScope = .all) async -> [LauncherResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || scope != .all else { return [] }
        // Providers run concurrently — Spotlight gathers dominate and would
        // otherwise serialize — but rows keep provider priority order.
        let providers = self.providers.filter { $0.searchScopes.contains(scope) }
        return await withTaskGroup(of: (Int, [LauncherResult]).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask { await (index, provider.results(for: trimmed)) }
            }
            var buckets = [[LauncherResult]](repeating: [], count: providers.count)
            for await (index, results) in group {
                buckets[index] = results
            }
            return buckets.flatMap(\.self).filter(scope.includes)
        }
    }
}

/// Wraps a provider behind a runtime switch (a Settings toggle), so the
/// provider chain stays fixed while the user flips preferences.
public struct ConditionalProvider: LauncherProvider {
    private let base: any LauncherProvider
    private let isEnabled: @Sendable () -> Bool

    public var searchScopes: Set<LauncherScope> {
        self.base.searchScopes
    }

    public init(_ base: any LauncherProvider, isEnabled: @escaping @Sendable () -> Bool) {
        self.base = base
        self.isEnabled = isEnabled
    }

    public func results(for query: String) async -> [LauncherResult] {
        guard self.isEnabled() else { return [] }
        return await self.base.results(for: query)
    }
}

public struct CalculatorProvider: LauncherProvider {
    public var searchScopes: Set<LauncherScope> {
        [.all]
    }

    public init() {}

    public func results(for query: String) async -> [LauncherResult] {
        guard let evaluation = CalculatorEngine.evaluate(query) else { return [] }
        return [.calculation(input: query, display: evaluation.display)]
    }
}

public struct WebSearchProvider: LauncherProvider {
    public var searchScopes: Set<LauncherScope> {
        [.all]
    }

    public init() {}

    /// URLComponents alone is wrong here: it leaves "+" literal in the query,
    /// which Google decodes as a space ("c++" would search for "c").
    public static func searchURL(for query: String) -> URL? {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        var components = URLComponents(string: "https://www.google.com/search")!
        components.percentEncodedQuery = "q=" + encoded
        return components.url
    }

    public func results(for query: String) async -> [LauncherResult] {
        // ":"-prefixed queries are commands — don't offer to google them.
        guard !query.hasPrefix(":"), let url = Self.searchURL(for: query) else { return [] }
        return [.webSearch(query: query, url: url)]
    }
}
