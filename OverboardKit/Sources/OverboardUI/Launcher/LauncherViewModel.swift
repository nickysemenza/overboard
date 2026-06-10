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
    private let fullRouter: QueryRouter
    private let hasSecondaryProviders: Bool
    private var searchTask: Task<Void, Never>?

    /// Secondary providers (apps, files, …) run in the debounced pass,
    /// sandwiched between the instant calculator and web rows.
    public init(secondaryProviders: [any LauncherProvider]) {
        let calculator = CalculatorProvider()
        let web = WebSearchProvider()
        self.instantRouter = QueryRouter(providers: [calculator, web])
        self.fullRouter = QueryRouter(providers: [calculator] + secondaryProviders + [web])
        self.hasSecondaryProviders = !secondaryProviders.isEmpty
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

            guard self.hasSecondaryProviders else { return }
            // Debounce Spotlight; per-keystroke metadata queries are wasteful.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let full = await self.fullRouter.results(for: query)
            guard !Task.isCancelled else { return }
            self.setResults(full)
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
