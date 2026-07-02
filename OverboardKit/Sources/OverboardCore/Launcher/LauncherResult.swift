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
    /// A ":"-prefixed launcher command. `subtitle` overrides the command's
    /// static subtitle when the provider resolved a live one (e.g. the `:stats`
    /// count); nil falls back to `command.subtitle`.
    case command(LauncherCommand, subtitle: String? = nil)
    /// A past search shown on the empty-field "recents" list; committing it
    /// refills the bar with `query` and re-runs the search.
    case recentSearch(query: String)
    /// Spotify's currently-playing track, pinned as a footer under every
    /// result list while music is playing (or paused).
    case nowPlaying(NowPlayingTrack)

    public var id: String {
        switch self {
        case let .calculation(input, display): "calc:\(input)=\(display)"
        case let .app(_, url): "app:\(url.path)"
        case let .snippet(snippet): "snippet:\(snippet.id)"
        case let .clip(item): "clip:\(item.id)"
        case let .file(_, url): "file:\(url.path)"
        case let .webSearch(query, _): "web:\(query)"
        case let .systemSetting(_, url): "setting:\(url.absoluteString)"
        case let .command(command, _): "command:\(command.rawValue)"
        case let .recentSearch(query): "recent:\(query)"
        // State in the id re-renders the row on play↔pause.
        case let .nowPlaying(track): "nowplaying:\(track.trackID):\(track.state.rawValue)"
        }
    }
}

/// A source of launcher rows, queried in priority order by `QueryRouter`.
/// Implementations must either be cheap enough to run on every keystroke
/// (calculator, web) or rely on the caller's debounce (Spotlight).
public protocol LauncherProvider: Sendable {
    func results(for query: String) async -> [LauncherResult]
}
