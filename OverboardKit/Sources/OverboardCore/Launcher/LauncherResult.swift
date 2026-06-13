import Foundation

/// One row in the launcher's results list.
public enum LauncherResult: Sendable, Equatable, Identifiable {
    case calculation(input: String, display: String)
    case app(name: String, url: URL)
    case snippet(Snippet)
    case clip(ClipItem)
    case file(name: String, url: URL)
    case webSearch(query: String, url: URL)
    /// A macOS System Settings pane; `url` is its `x-apple.systempreferences:` link.
    case systemSetting(name: String, url: URL)
    case command(LauncherCommand)

    public var id: String {
        switch self {
        case let .calculation(input, display): "calc:\(input)=\(display)"
        case let .app(_, url): "app:\(url.path)"
        case let .snippet(snippet): "snippet:\(snippet.id)"
        case let .clip(item): "clip:\(item.id)"
        case let .file(_, url): "file:\(url.path)"
        case let .webSearch(query, _): "web:\(query)"
        case let .systemSetting(_, url): "setting:\(url.absoluteString)"
        case let .command(command): "command:\(command.rawValue)"
        }
    }
}

/// A source of launcher rows, queried in priority order by `QueryRouter`.
/// Implementations must either be cheap enough to run on every keystroke
/// (calculator, web) or rely on the caller's debounce (Spotlight).
public protocol LauncherProvider: Sendable {
    func results(for query: String) async -> [LauncherResult]
}
