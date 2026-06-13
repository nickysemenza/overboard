import Foundation
@testable import OverboardCore
import Testing

struct CommandProviderTests {
    private let provider = CommandProvider()

    @Test func versionCommandMatchesFullName() async {
        let results = await provider.results(for: ":version")
        #expect(results == [.command(.version)])
    }

    @Test func prefixMatchesPartialName() async {
        // ":v" should already surface ":version".
        #expect(await self.provider.results(for: ":v") == [.command(.version)])
        #expect(await self.provider.results(for: ":ver") == [.command(.version)])
    }

    @Test func bareColonMatchesNothing() async {
        #expect(await self.provider.results(for: ":").isEmpty)
        #expect(await self.provider.results(for: ":   ").isEmpty)
    }

    @Test func nonCommandQueryIsIgnored() async {
        #expect(await self.provider.results(for: "version").isEmpty)
        #expect(await self.provider.results(for: "hello").isEmpty)
    }

    /// The ":" prefix is a command, not something to google — the web row
    /// must drop out so command mode reads clean.
    @Test func webSearchSkipsCommandQueries() async {
        #expect(await WebSearchProvider().results(for: ":version").isEmpty)
        #expect(await WebSearchProvider().results(for: "version").isEmpty == false)
    }
}
