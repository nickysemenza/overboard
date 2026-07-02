import Foundation
@testable import OverboardCore
import Testing

struct CommandProviderTests {
    private let provider = CommandProvider()

    /// Pulls the command out of each row, ignoring any resolved subtitle.
    private func commands(_ results: [LauncherResult]) -> [LauncherCommand] {
        results.compactMap {
            if case let .command(command, _) = $0 { command } else { nil }
        }
    }

    @Test func versionCommandMatchesFullName() async {
        let results = await provider.results(for: ":version")
        #expect(self.commands(results) == [.version])
    }

    @Test func prefixMatchesPartialName() async {
        // ":v" should already surface ":version".
        #expect(await self.commands(self.provider.results(for: ":v")) == [.version])
        #expect(await self.commands(self.provider.results(for: ":ver")) == [.version])
    }

    /// ":s" is ambiguous across stats and settings — both must come back, in
    /// declaration order.
    @Test func prefixCanMatchMultipleCommands() async {
        #expect(await self.commands(self.provider.results(for: ":s")) == [.stats, .settings])
    }

    @Test func bareColonListsAllIncludedCommands() async {
        // Bare ":" is the command menu: every case, in declaration order.
        #expect(await self.commands(self.provider.results(for: ":")) == LauncherCommand.allCases)
        #expect(await self.commands(self.provider.results(for: ":   ")) == LauncherCommand.allCases)
    }

    @Test func nonCommandQueryIsIgnored() async {
        #expect(await self.provider.results(for: "version").isEmpty)
        #expect(await self.provider.results(for: "hello").isEmpty)
    }

    /// `isIncluded` hides commands that don't apply right now (e.g. `.resume`
    /// while capturing) — filtered rows never surface, even on an exact prefix.
    @Test func isIncludedFiltersHiddenCommands() async {
        let provider = CommandProvider(isIncluded: { $0 != .resume })
        // Bare ":" drops the hidden command from the full list.
        #expect(await self.commands(provider.results(for: ":")) == LauncherCommand.allCases.filter { $0 != .resume })
        // An exact-name query for the hidden command matches nothing — and
        // since `.resume` is the only "r" command, ":r" drops out entirely.
        #expect(await provider.results(for: ":resume").isEmpty)
        #expect(await provider.results(for: ":r").isEmpty)
        // A non-hidden command still matches on its own prefix.
        #expect(await self.commands(provider.results(for: ":c")) == [.clear])
    }

    /// `dynamicSubtitle` overrides only the command it targets; other rows keep
    /// their static subtitle (surfaced as a nil override).
    @Test func dynamicSubtitleOverridesTargetedCommand() async {
        let provider = CommandProvider(
            dynamicSubtitle: { $0 == .stats ? "42 items" : nil }
        )
        let results = await provider.results(for: ":")
        for result in results {
            guard case let .command(command, subtitle) = result else { continue }
            if command == .stats {
                #expect(subtitle == "42 items")
            } else {
                #expect(subtitle == nil)
            }
        }
    }

    /// The ":" prefix is a command, not something to google — the web row
    /// must drop out so command mode reads clean.
    @Test func webSearchSkipsCommandQueries() async {
        #expect(await WebSearchProvider().results(for: ":version").isEmpty)
        #expect(await WebSearchProvider().results(for: "version").isEmpty == false)
    }
}
