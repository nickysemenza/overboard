import Foundation
import Observation
import OverboardCore

/// State machine for the launcher bar: instant calculator/web rows on every
/// keystroke, Spotlight file rows spliced in after a debounce.
@MainActor
@Observable
public final class LauncherViewModel {
    public enum CommitModifier: Sendable {
        case none, command, option
    }

    public var query = ""
    public private(set) var results: [LauncherResult] = []
    public var selectedIndex = 0
    /// Bumped on every summon so the view re-asserts text-field focus
    /// (onAppear only fires once — the hosting view is reused).
    public private(set) var showGeneration = 0

    // Effects, executed by the app layer.
    public var onCopyText: (String) -> Void = { _ in }
    public var onPasteText: (String) -> Void = { _ in }
    public var onOpenFile: (URL) -> Void = { _ in }
    public var onRevealFile: (URL) -> Void = { _ in }
    public var onCopyPath: (String) -> Void = { _ in }
    public var onOpenWebSearch: (URL) -> Void = { _ in }
    /// Lets the panel controller resize as rows come and go.
    public var onResultCountChanged: (Int) -> Void = { _ in }

    private let instantRouter: QueryRouter
    private let secondaryProviders: [any LauncherProvider]
    private var searchTask: Task<Void, Never>?

    /// Instant providers (apps) answer from memory and render on every
    /// keystroke alongside the calculator; secondary providers (files) run
    /// in the debounced pass and splice in above the web row.
    public init(instantProviders: [any LauncherProvider] = [], secondaryProviders: [any LauncherProvider]) {
        self.instantRouter = QueryRouter(
            providers: [CalculatorProvider()] + instantProviders + [WebSearchProvider()]
        )
        self.secondaryProviders = secondaryProviders
    }

    public func prepareForShow() {
        self.searchTask?.cancel()
        self.query = ""
        self.selectedIndex = 0
        self.showGeneration += 1
        self.setResults([])
    }

    public func scheduleSearch() {
        self.searchTask?.cancel()
        let query = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            self.selectedIndex = 0
            self.setResults([])
            return
        }
        self.searchTask = Task {
            // Calculator + web are effectively synchronous — show them now.
            let instant = await self.instantRouter.results(for: query)
            guard !Task.isCancelled else { return }
            self.selectedIndex = 0
            self.setResults(instant)

            let providers = self.secondaryProviders
            guard !providers.isEmpty else { return }
            // Debounce Spotlight; per-keystroke metadata queries are wasteful.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }

            // Splice each provider's rows in as it finishes — apps come back
            // well before the broad home-folder file query, and waiting for
            // the slowest provider made the whole bar feel sluggish.
            let head = instant.filter { if case .webSearch = $0 { false } else { true } }
            let tail = instant.filter { if case .webSearch = $0 { true } else { false } }
            var buckets = [[LauncherResult]](repeating: [], count: providers.count)
            await withTaskGroup(of: (Int, [LauncherResult]).self) { group in
                for (index, provider) in providers.enumerated() {
                    group.addTask { await (index, provider.results(for: query)) }
                }
                for await (index, rows) in group {
                    guard !Task.isCancelled else { return }
                    buckets[index] = rows
                    self.setResults(head + buckets.flatMap(\.self) + tail)
                }
            }
        }
    }

    public func moveSelection(_ delta: Int) {
        guard !self.results.isEmpty else { return }
        self.selectedIndex = min(max(self.selectedIndex + delta, 0), self.results.count - 1)
    }

    public func commit(modifier: CommitModifier = .none) {
        guard self.results.indices.contains(self.selectedIndex) else { return }
        switch self.results[self.selectedIndex] {
        case let .calculation(_, display):
            modifier == .command ? self.onPasteText(display) : self.onCopyText(display)
        case let .app(_, url), let .file(_, url):
            switch modifier {
            case .none: self.onOpenFile(url)
            case .command: self.onRevealFile(url)
            case .option: self.onCopyPath(url.path)
            }
        case let .webSearch(_, url):
            self.onOpenWebSearch(url)
        }
    }

    private func setResults(_ newResults: [LauncherResult]) {
        obTrace("launcher results: \(newResults.map(\.id))")
        let countChanged = newResults.count != self.results.count
        self.results = newResults
        if self.selectedIndex >= newResults.count {
            self.selectedIndex = max(newResults.count - 1, 0)
        }
        if countChanged {
            self.onResultCountChanged(newResults.count)
        }
    }
}
