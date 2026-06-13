import Foundation

/// Concatenates provider results in priority order. The view model owns two
/// of these — an instant one (calculator + web) rendered on every keystroke,
/// and a full one (+ Spotlight) swapped in after the debounce — so the bar
/// never waits on file I/O to show the math.
public struct QueryRouter: Sendable {
    private let providers: [any LauncherProvider]

    public init(providers: [any LauncherProvider]) {
        self.providers = providers
    }

    public func results(for query: String) async -> [LauncherResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Providers run concurrently — Spotlight gathers dominate and would
        // otherwise serialize — but rows keep provider priority order.
        let providers = self.providers
        return await withTaskGroup(of: (Int, [LauncherResult]).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask { await (index, provider.results(for: trimmed)) }
            }
            var buckets = [[LauncherResult]](repeating: [], count: providers.count)
            for await (index, results) in group {
                buckets[index] = results
            }
            return buckets.flatMap(\.self)
        }
    }
}

/// Wraps a provider behind a runtime switch (a Settings toggle), so the
/// provider chain stays fixed while the user flips preferences.
public struct ConditionalProvider: LauncherProvider {
    private let base: any LauncherProvider
    private let isEnabled: @Sendable () -> Bool

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
    public init() {}

    public func results(for query: String) async -> [LauncherResult] {
        guard let evaluation = CalculatorEngine.evaluate(query) else { return [] }
        return [.calculation(input: query, display: evaluation.display)]
    }
}

public struct WebSearchProvider: LauncherProvider {
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
