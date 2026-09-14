import Foundation

/// The launcher's `>` prefix: `> brew upgrade` runs `brew upgrade` in Ghostty.
/// `isAvailable` is injected (rather than read here) so OverboardCore stays
/// free of the AppKit/LaunchServices lookup, and it's checked only after the
/// prefix and non-empty-command tests pass — a lookup per keystroke only
/// happens once the user has actually typed `>`.
public struct ShellCommandProvider: LauncherProvider {
    private let isAvailable: @Sendable () -> Bool

    public var searchScopes: Set<LauncherScope> {
        [.all]
    }

    public init(isAvailable: @escaping @Sendable () -> Bool) {
        self.isAvailable = isAvailable
    }

    public func results(for query: String) async -> [LauncherResult] {
        guard query.hasPrefix(">") else { return [] }
        let command = query.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, self.isAvailable() else { return [] }
        return [.shellCommand(command)]
    }
}
