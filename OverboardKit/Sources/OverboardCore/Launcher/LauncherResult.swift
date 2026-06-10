import Foundation

/// One row in the launcher's results list.
public enum LauncherResult: Sendable, Equatable, Identifiable {
    case calculation(input: String, display: String)
    case app(name: String, url: URL)
    case file(name: String, url: URL)
    case webSearch(query: String, url: URL)

    public var id: String {
        switch self {
        case let .calculation(input, display): "calc:\(input)=\(display)"
        case let .app(_, url): "app:\(url.path)"
        case let .file(_, url): "file:\(url.path)"
        case let .webSearch(query, _): "web:\(query)"
        }
    }
}

/// A source of launcher rows, queried in priority order by `QueryRouter`.
/// Implementations must either be cheap enough to run on every keystroke
/// (calculator, web) or rely on the caller's debounce (Spotlight).
public protocol LauncherProvider: Sendable {
    func results(for query: String) async -> [LauncherResult]
}
