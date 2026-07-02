import Foundation

/// A labeled group of launcher rows. `QueryRouter` merges providers in
/// priority order, so a provider's rows are already contiguous — headers
/// annotate those consecutive runs rather than re-sorting the list.
public enum LauncherSection: Sendable, Equatable {
    case commands, apps, snippets, clipboard, files, settings, recent

    public var title: String {
        switch self {
        case .commands: "Commands"
        case .apps: "Apps"
        case .snippets: "Snippets"
        case .clipboard: "Clipboard"
        case .files: "Files"
        case .settings: "System Settings"
        case .recent: "Recent"
        }
    }

    /// The section a row belongs to. Calculation, web-search, and now-playing
    /// rows are singletons that read fine bare, so they're never headered.
    public static func section(for result: LauncherResult) -> LauncherSection? {
        switch result {
        case .command: .commands
        case .app: .apps
        case .snippet: .snippets
        case .clip: .clipboard
        case .file: .files
        case .systemSetting: .settings
        case .recentSearch: .recent
        case .calculation, .webSearch, .nowPlaying: nil
        }
    }

    /// Pairs each row with the header (if any) to draw above it: the first row
    /// of each consecutive run of a headered section gets that section's
    /// title; runs of never-headered kinds get none. Groups consecutive runs
    /// only — the flat order (and thus the selection index) is untouched.
    public static func annotate(_ results: [LauncherResult]) -> [(header: String?, result: LauncherResult)] {
        var previous: LauncherSection?
        return results.map { result in
            let section = self.section(for: result)
            defer { previous = section }
            return (header: section != previous ? section?.title : nil, result: result)
        }
    }
}
