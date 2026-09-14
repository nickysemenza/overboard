import Foundation
@testable import OverboardCore
import Testing

struct ShellCommandProviderTests {
    @Test func prefixedCommandProducesShellResult() async {
        let provider = ShellCommandProvider(isAvailable: { true })
        let results = await provider.results(for: "> brew upgrade")
        #expect(results == [.shellCommand("brew upgrade")])
    }

    @Test func barePrefixProducesNothing() async {
        let provider = ShellCommandProvider(isAvailable: { true })
        let results = await provider.results(for: ">")
        #expect(results.isEmpty)
    }

    @Test func prefixFollowedByWhitespaceOnlyProducesNothing() async {
        let provider = ShellCommandProvider(isAvailable: { true })
        let results = await provider.results(for: "> ")
        #expect(results.isEmpty)
    }

    @Test func unavailableProducesNothing() async {
        let provider = ShellCommandProvider(isAvailable: { false })
        let results = await provider.results(for: "> brew upgrade")
        #expect(results.isEmpty)
    }

    @Test func unprefixedQueryProducesNothing() async {
        let provider = ShellCommandProvider(isAvailable: { true })
        let results = await provider.results(for: "brew")
        #expect(results.isEmpty)
    }
}
