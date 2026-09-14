import Foundation

/// Query-shape helpers shared across launcher providers.
public enum LauncherQuery {
    /// True for a ":"-prefixed launcher command or a ">"-prefixed shell
    /// command — both are "command mode" and should suppress the app/web/AI/
    /// settings rows that would otherwise crowd the command row out.
    public static func isCommandLike(_ query: String) -> Bool {
        query.hasPrefix(":") || query.hasPrefix(">")
    }
}
