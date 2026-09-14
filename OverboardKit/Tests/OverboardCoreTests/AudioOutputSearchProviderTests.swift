@testable import OverboardCore
import Testing

struct AudioOutputSearchProviderTests {
    private static let builtIn = AudioOutputDevice(id: 1, name: "MacBook Pro Speakers", isDefault: false)
    private static let airPods = AudioOutputDevice(id: 2, name: "AirPods Pro", isDefault: true)

    private func provider(devices: [AudioOutputDevice]) -> AudioOutputSearchProvider {
        AudioOutputSearchProvider(devices: { devices })
    }

    @Test func nameQueryMatchesDevice() async {
        let results = await self.provider(devices: [Self.builtIn, Self.airPods]).results(for: "airp")
        #expect(results == [.audioOutput(Self.airPods)])
    }

    @Test func keywordQueryListsAllDevicesDefaultFirst() async {
        let results = await self.provider(devices: [Self.builtIn, Self.airPods]).results(for: "audio")
        #expect(results == [.audioOutput(Self.airPods), .audioOutput(Self.builtIn)])
    }

    @Test func keywordPrefixAlsoMatches() async {
        let results = await self.provider(devices: [Self.builtIn, Self.airPods]).results(for: "out")
        #expect(results == [.audioOutput(Self.airPods), .audioOutput(Self.builtIn)])
    }

    @Test func emptyDeviceListYieldsNothing() async {
        let results = await self.provider(devices: []).results(for: "audio")
        #expect(results.isEmpty)
    }

    @Test func nonMatchingNameYieldsNothing() async {
        let results = await self.provider(devices: [Self.builtIn, Self.airPods]).results(for: "zzz")
        #expect(results.isEmpty)
    }

    /// A one-letter query must not fan out into every output device, and a
    /// two-letter keyword prefix (`au`) isn't "audio" yet — only a device
    /// name can match that short.
    @Test func shortQueriesNeverListEveryDevice() async {
        let provider = self.provider(devices: [Self.builtIn, Self.airPods])
        #expect(await provider.results(for: "a").isEmpty)
        #expect(await provider.results(for: "au").isEmpty)
        #expect(await provider.results(for: "ai") == [.audioOutput(Self.airPods)])
    }

    @Test func commandLikeQueriesYieldNothing() async {
        let provider = self.provider(devices: [Self.builtIn, Self.airPods])
        #expect(await provider.results(for: ":audio").isEmpty)
        #expect(await provider.results(for: "> audio").isEmpty)
    }
}
