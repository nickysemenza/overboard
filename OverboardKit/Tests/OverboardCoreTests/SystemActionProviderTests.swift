@testable import OverboardCore
import Testing

struct SystemActionProviderTests {
    private func provider(isAvailable: @escaping @Sendable (SystemAction) -> Bool = { _ in
        true
    }) -> SystemActionProvider {
        SystemActionProvider(isAvailable: isAvailable)
    }

    @Test func matchesKeywordNotInTitle() async {
        let results = await self.provider().results(for: "loc")
        #expect(results == [.systemAction(.lockScreen)])
    }

    @Test func matchesKeywordAlias() async {
        let results = await self.provider().results(for: "reboot")
        #expect(results == [.systemAction(.restart)])
    }

    @Test func hidesUnavailableActions() async {
        let results = await self.provider(isAvailable: { $0 != .lockScreen }).results(for: "loc")
        #expect(results.isEmpty)
    }

    @Test func tooShortQueryYieldsNothing() async {
        let results = await self.provider().results(for: "lo")
        #expect(results.isEmpty)
    }

    @Test func colonPrefixedQueryYieldsNothing() async {
        let results = await self.provider().results(for: ":lock")
        #expect(results.isEmpty)
    }

    @Test func greaterThanPrefixedQueryYieldsNothing() async {
        let results = await self.provider().results(for: ">lock")
        #expect(results.isEmpty)
    }
}
