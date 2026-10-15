import Foundation

/// One row in the launcher's results list.
public enum LauncherResult: Sendable, Equatable, Identifiable {
    case calculation(input: String, display: String)
    case app(name: String, url: URL)
    case snippet(Snippet)
    case clip(ClipItem)
    case file(name: String, url: URL, info: FileSearchInfo = FileSearchInfo())
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
    /// A free-text Apple Intelligence instruction run over the current
    /// clipboard text — the launcher's "Ask AI" fallback row. Sits last in the
    /// instant section (after the web row), above the pinned now-playing footer.
    case askAI(prompt: String)
    /// A macOS system action (lock, sleep, restart) run via OverboardMac's
    /// `SystemActionService`.
    case systemAction(SystemAction)
    /// A CoreAudio output device; committing switches the system default output.
    case audioOutput(AudioOutputDevice)
    /// A user-defined quicklink (Settings → General). `query` is the trailing
    /// text typed after the keyword — used to render the row's title — and
    /// `url` is the already-resolved destination (nil when the template
    /// didn't parse as a URL).
    case quicklink(Quicklink, query: String, url: URL)
    /// A ">"-prefixed command line; committing runs it in Ghostty.
    case shellCommand(String)
    /// An upcoming calendar event: the pinned up-next row, or a `cal`/`today`
    /// listing.
    case calendarEvent(CalendarEvent)

    public var id: String {
        switch self {
        case let .calculation(input, display): "calc:\(input)=\(display)"
        case let .app(_, url): "app:\(url.path)"
        case let .snippet(snippet): "snippet:\(snippet.id)"
        case let .clip(item): "clip:\(item.id)"
        case let .file(_, url, _): "file:\(url.path)"
        case let .webSearch(query, _): "web:\(query)"
        case let .systemSetting(_, url): "setting:\(url.absoluteString)"
        case let .command(command, _): "command:\(command.rawValue)"
        case let .recentSearch(query): "recent:\(query)"
        // State in the id re-renders the row on play↔pause.
        case let .nowPlaying(track): "nowplaying:\(track.trackID):\(track.state.rawValue)"
        case let .askAI(prompt): "askai:\(prompt)"
        case let .systemAction(action): "sysaction:\(action.rawValue)"
        // State in the id re-renders the checkmark when the default changes.
        case let .audioOutput(device): "audio:\(device.id):\(device.isDefault)"
        case let .quicklink(link, query, _): "quicklink:\(link.keyword):\(query)"
        case let .shellCommand(command): "shell:\(command)"
        case let .calendarEvent(event): "calendar:\(event.id)"
        }
    }
}

/// A source of launcher rows, queried in priority order by `QueryRouter`.
/// Implementations must either be cheap enough to run on every keystroke
/// (calculator, web, apps) or run concurrently off the main pass and merge in
/// as they finish (files, snippets, clipboard) — there is no debounce to lean on.
public protocol LauncherProvider: Sendable {
    var searchScopes: Set<LauncherScope> { get }
    func results(for query: String) async -> [LauncherResult]
    func results(for query: String, context: LauncherSearchContext) async -> [LauncherResult]
}

public extension LauncherProvider {
    func results(for query: String, context _: LauncherSearchContext) async -> [LauncherResult] {
        await self.results(for: query)
    }

    var searchScopes: Set<LauncherScope> {
        Set(LauncherScope.allCases)
    }
}

public struct LauncherSearchContext: Sendable {
    /// Exact-query picks: rows chosen for exactly the query now typed.
    public var usage: [String: Int]
    /// Picks made for longer queries that start with this one ("notes"
    /// counts toward "not"), already weighted by how much of that query was
    /// typed and how recently the row was picked. Unlike `usage` these only
    /// add to the blended score; they never pin a row.
    public var carried: [String: Double]
    public var counts: [String: Int]
    public var lastUsed: [String: Double]
    public var now: Date
    /// Folders the user has picked a file from. A noise location stops being
    /// demoted for files directly inside one of these.
    public var pickedFolders: Set<String>
    public var noiseRules: NoiseRules

    public init(
        usage: [String: Int] = [:],
        carried: [String: Double] = [:],
        counts: [String: Int] = [:],
        lastUsed: [String: Double] = [:],
        now: Date = .now,
        noiseRules: NoiseRules = NoiseRules()
    ) {
        self.usage = usage
        self.noiseRules = noiseRules
        self.carried = carried
        self.counts = counts
        self.lastUsed = lastUsed
        self.now = now
        self.pickedFolders = Set(counts.keys.compactMap { id in
            id.hasPrefix("file:") ? (String(id.dropFirst(5)) as NSString).deletingLastPathComponent : nil
        })
    }

    /// Splits the persisted `query \u{1F} id` pick counts into this query's
    /// exact-query picks and the picks carried over from longer queries.
    public init(
        query: String,
        selectionUsage: [String: Int],
        counts: [String: Int],
        lastUsed: [String: Double],
        now: Date = .now,
        noiseRules: NoiseRules = NoiseRules()
    ) {
        let needle = AppMatcher.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        var usage: [String: Int] = [:], carried: [String: Double] = [:]
        for (key, value) in selectionUsage {
            guard !needle.isEmpty, let separator = key.firstIndex(of: "\u{1F}") else { continue }
            let picked = key[..<separator], id = String(key[key.index(after: separator)...])
            if picked == needle {
                usage[id] = value
            } else if picked.hasPrefix(needle) {
                // No per-query timestamps are kept, so the row's own last
                // pick stands in: of two rows claiming a prefix, the more
                // recently picked one carries more weight.
                let ageDays = max(0, now.timeIntervalSince1970 - lastUsed[id, default: 0]) / 86400
                carried[id, default: 0] += Double(value) * Double(needle.count) / Double(picked.count)
                    / (1 + ageDays / 14)
            }
        }
        self.init(
            usage: usage, carried: carried, counts: counts, lastUsed: lastUsed, now: now, noiseRules: noiseRules
        )
    }

    public func frecency(_ id: String) -> Double {
        LauncherFrecency.score(id: id, counts: self.counts, lastUsed: self.lastUsed, now: self.now)
    }

    public func sorted(
        _ results: [LauncherResult],
        query: String,
        aliases: [String: String] = [:]
    ) -> [LauncherResult] {
        LauncherRanking.sorted(results, query: query, aliases: aliases, context: self)
    }
}
