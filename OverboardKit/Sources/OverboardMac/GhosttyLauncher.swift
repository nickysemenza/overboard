import AppKit

/// Runs a `>`-prefixed launcher command in Ghostty (`com.mitchellh.ghostty`).
///
/// Verified manually against Ghostty 1.3.1: `open -na Ghostty.app --args
/// --wait-after-command=true -e <shell> -l -c '<command>'` opens a window,
/// runs the command, and leaves the window open afterward — which is what
/// `NSWorkspace.OpenConfiguration` below reproduces. `createsNewApplicationInstance
/// = true` is required (Ghostty's own CLI docs recommend `open -na` for
/// exactly this reason): without it, `NSWorkspace` just activates an
/// already-running Ghostty instance and silently drops the `-e` arguments, so
/// the command never runs. The tradeoff, confirmed with `lsappinfo`, is a
/// second Ghostty entry (and Dock icon) alongside an already-running
/// instance — an accepted cost of "the command always runs" over "one Dock
/// icon."
public nonisolated enum GhosttyLauncher {
    public static let bundleID = "com.mitchellh.ghostty"

    /// The user's login shell from the passwd database — not `$SHELL`, which
    /// a LaunchServices-launched app doesn't reliably inherit — so a fish or
    /// bash user gets their own shell, aliases and all. `/bin/zsh` only if
    /// the lookup fails.
    public nonisolated static var loginShell: String {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return "/bin/zsh" }
        let path = String(cString: shell)
        return path.isEmpty ? "/bin/zsh" : path
    }

    /// `-l -c` as separate flags rather than `-lc`: every common shell
    /// (fish, bash, zsh) accepts them spelled out, whereas combined short
    /// options depend on the shell's option parser.
    public nonisolated static func arguments(for command: String, shell: String) -> [String] {
        ["--wait-after-command=true", "-e", shell, "-l", "-c", command]
    }

    public nonisolated static func isInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: self.bundleID) != nil
    }

    /// Throws (rather than flashing a HUD itself) because `OverboardMac`
    /// doesn't depend on `OverboardUI`, where `HUDController` lives — the
    /// caller (`AppServices+Callbacks.swift`, which does) flashes "Couldn't
    /// open Ghostty" on failure, the same division used by `FileOpening.open`
    /// / `onOpenFile`.
    public static func run(_ command: String) async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: self.bundleID) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = self.arguments(for: command, shell: self.loginShell)
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
