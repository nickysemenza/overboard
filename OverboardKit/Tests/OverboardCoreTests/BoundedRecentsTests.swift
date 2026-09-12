@testable import OverboardCore
import Testing

struct BoundedRecentsTests {
    @Test func normalizesDuplicatesAndTrimsOldestValues() {
        let recents = BoundedRecents(mostRecentFirst: ["new", "middle", "new", "old"], limit: 2)
        #expect(recents.mostRecentFirst == ["new", "middle"])
    }

    @Test func recordingMovesExistingValueToTheFrontWithoutDroppingIt() {
        var recents = BoundedRecents(mostRecentFirst: ["new", "middle", "old"], limit: 3)
        recents.record("middle")
        #expect(recents.mostRecentFirst == ["middle", "new", "old"])
    }

    @Test func recordingNewValueDropsOnlyTheOldestValue() {
        var recents = BoundedRecents(mostRecentFirst: ["new", "middle", "old"], limit: 3)
        recents.record("latest")
        #expect(recents.mostRecentFirst == ["latest", "new", "middle"])
    }

    @Test func removingAndPruningPreserveRelativeOrder() {
        var recents = BoundedRecents(mostRecentFirst: ["new", "middle", "old"], limit: 3)
        recents.remove("middle")
        recents.prune { $0 != "old" }
        #expect(recents.mostRecentFirst == ["new"])
    }
}
