import Foundation
@testable import OverboardCLI
import Testing

/// `CommandTests` checks that `Overboard.run` *returns* the right `ExitCode`
/// case — but the real contract scripts depend on is the OS-level exit status
/// `Overboard.main()` produces via `exit(code.rawValue)`. These exit tests
/// spawn the process and assert on that actual status, one per documented
/// exit code that can be triggered deterministically in-process.
///
/// `.environment` (2) is intentionally not covered here: it only fires when
/// `OverboardDatabase.defaultDirectory()` — `~/Library/Application
/// Support/Overboard`, resolved from the real per-user home directory record,
/// not the `HOME` environment variable — can't be opened. There's no seam to
/// point that at a scratch directory without adding dependency injection to
/// the CLI, which is out of scope here.
struct ExitCodeTests {
    @Test func exitsOkOnSuccess() async {
        await #expect(processExitsWith: .exitCode(ExitCode.ok.rawValue)) {
            await exit(Overboard.run(["help"]).rawValue)
        }
    }

    @Test func exitsUsageForAMalformedCommandLine() async {
        await #expect(processExitsWith: .exitCode(ExitCode.usage.rawValue)) {
            // No subcommand at all is the simplest way to hit this deterministically.
            await exit(Overboard.run([]).rawValue)
        }
    }

    @Test func exitsNotFoundForAWellFormedEmptyResult() async {
        await #expect(processExitsWith: .exitCode(ExitCode.notFound.rawValue)) {
            // `emitList` is the pure sink every read command funnels through, so
            // it exercises the notFound contract without touching a real store.
            exit(Overboard.emitList([], json: false).rawValue)
        }
    }
}
