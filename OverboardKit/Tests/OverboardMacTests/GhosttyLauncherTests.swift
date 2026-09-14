@testable import OverboardMac
import Testing

struct GhosttyLauncherTests {
    /// Regression: the launcher once hardcoded `/bin/zsh -lc`, which ran fish
    /// and bash users' commands in the wrong shell. The shell must come from
    /// the passwd entry and be passed with separate `-l` / `-c` flags.
    @Test func argumentsUseTheGivenShellWithSeparateFlags() {
        let arguments = GhosttyLauncher.arguments(for: "brew upgrade", shell: "/opt/homebrew/bin/fish")
        #expect(arguments == ["--wait-after-command=true", "-e", "/opt/homebrew/bin/fish", "-l", "-c", "brew upgrade"])
    }

    @Test func loginShellIsAnAbsolutePath() {
        #expect(GhosttyLauncher.loginShell.hasPrefix("/"))
    }
}
