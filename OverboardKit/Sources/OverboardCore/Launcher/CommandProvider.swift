import Foundation

/// Launcher commands — typed behind a ":" prefix so they read as commands, not
/// search. ":version" today; the prefix is the namespace for ":settings",
/// ":quit", etc. later. Title/subtitle live here so the provider and the row
/// can't drift apart.
public enum LauncherCommand: String, Sendable, Equatable, CaseIterable {
    case version

    public var title: String {
        switch self {
        case .version: "Overboard \(AppVersion.marketing)"
        }
    }

    public var subtitle: String {
        switch self {
        case .version: AppVersion.detail
        }
    }
}

/// Matches ":"-prefixed queries against the command list by name prefix, so
/// ":v" already surfaces ":version". Returns nothing for a bare ":".
public struct CommandProvider: LauncherProvider {
    public init() {}

    public func results(for query: String) async -> [LauncherResult] {
        guard query.hasPrefix(":") else { return [] }
        let name = query.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return [] }
        return LauncherCommand.allCases
            .filter { $0.rawValue.hasPrefix(name) }
            .map { .command($0) }
    }
}
