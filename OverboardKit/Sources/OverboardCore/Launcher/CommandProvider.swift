import Foundation

/// Launcher commands — typed behind a ":" prefix so they read as commands, not
/// search. The prefix is the namespace; title/subtitle live here so the
/// provider and the row can't drift apart. `.version` is the always-static
/// case; the rest drive real app actions wired up in AppServices.
public enum LauncherCommand: String, Sendable, Equatable, CaseIterable {
    case version
    case stats
    case pause
    case resume
    case clear
    case settings

    public var title: String {
        switch self {
        case .version: "Overboard \(AppVersion.marketing)"
        case .stats: "Library stats"
        case .pause: "Pause clipboard capture"
        case .resume: "Resume clipboard capture"
        case .clear: "Clear clipboard history"
        case .settings: "Open Settings"
        }
    }

    /// The default subtitle. `.stats` is overridden at runtime with a live count
    /// via `CommandProvider.dynamicSubtitle`; the static string here is only the
    /// fallback (e.g. if the store lookup fails).
    public var subtitle: String {
        switch self {
        case .version: AppVersion.detail
        case .stats: "Count clips by kind"
        case .pause: "Stop watching the clipboard"
        case .resume: "Start watching the clipboard again"
        case .clear: "Remove all clips (keeps pinned)"
        case .settings: "Preferences and options"
        }
    }
}

/// Matches ":"-prefixed queries against the command list by name prefix, so
/// ":v" already surfaces ":version" and bare ":" lists every included command.
///
/// Kept pure: OverboardCore has no access to the monitor or store, so the two
/// pieces of app state it needs are injected as closures —
///  - `isIncluded` hides commands that don't apply right now (e.g. `.resume`
///    while capturing, `.pause` while paused).
///  - `dynamicSubtitle` fills in a live subtitle (the `.stats` count).
public struct CommandProvider: LauncherProvider {
    private let isIncluded: @Sendable (LauncherCommand) -> Bool
    private let dynamicSubtitle: @Sendable (LauncherCommand) async -> String?

    public init(
        isIncluded: @escaping @Sendable (LauncherCommand) -> Bool = { _ in true },
        dynamicSubtitle: @escaping @Sendable (LauncherCommand) async -> String? = { _ in nil }
    ) {
        self.isIncluded = isIncluded
        self.dynamicSubtitle = dynamicSubtitle
    }

    public func results(for query: String) async -> [LauncherResult] {
        guard query.hasPrefix(":") else { return [] }
        let name = query.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
        // Bare ":" lists every included command; a partial name prefix-filters.
        let matches = LauncherCommand.allCases
            .filter { self.isIncluded($0) }
            .filter { name.isEmpty || $0.rawValue.hasPrefix(name) }

        var results: [LauncherResult] = []
        results.reserveCapacity(matches.count)
        for command in matches {
            let subtitle = await self.dynamicSubtitle(command)
            results.append(.command(command, subtitle: subtitle))
        }
        return results
    }
}
