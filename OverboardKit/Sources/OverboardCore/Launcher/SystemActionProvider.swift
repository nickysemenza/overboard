import Foundation

/// Surfaces lock/sleep/restart as launcher rows once the query looks like a
/// deliberate search for one — never on a bare "l" or "s" that would crowd
/// out everything else typed so far.
///
/// `isAvailable` is injected (rather than read here) so OverboardCore stays
/// free of `SystemActionService`'s dlsym lookup, and tests can hide or show
/// any action without touching the private symbol at all.
public struct SystemActionProvider: LauncherProvider {
    public var searchScopes: Set<LauncherScope> {
        [.all]
    }

    private let isAvailable: @Sendable (SystemAction) -> Bool

    public init(isAvailable: @escaping @Sendable (SystemAction) -> Bool) {
        self.isAvailable = isAvailable
    }

    public func results(for query: String) async -> [LauncherResult] {
        guard query.count >= 3, !LauncherQuery.isCommandLike(query) else { return [] }
        return SystemAction.allCases
            .filter(self.isAvailable)
            .filter { SearchMatcher.match(query: query, title: $0.title, context: $0.keywords) != nil }
            .map { .systemAction($0) }
    }
}
