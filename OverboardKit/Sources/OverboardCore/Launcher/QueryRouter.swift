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
        var results: [LauncherResult] = []
        for provider in self.providers {
            results += await provider.results(for: trimmed)
        }
        return results
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
        guard let url = Self.searchURL(for: query) else { return [] }
        return [.webSearch(query: query, url: url)]
    }
}
