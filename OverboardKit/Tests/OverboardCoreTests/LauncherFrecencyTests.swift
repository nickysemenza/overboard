import Foundation
@testable import OverboardCore
import Testing

struct LauncherFrecencyTests {
    @Test func balancesFrequencyWithRecencyAndKeepsUnseenRowsStable() {
        let old = LauncherResult.app(name: "Old favorite", url: URL(fileURLWithPath: "/Apps/old.app"))
        let frequent = LauncherResult.app(name: "Current favorite", url: URL(fileURLWithPath: "/Apps/frequent.app"))
        let new = LauncherResult.app(name: "New app", url: URL(fileURLWithPath: "/Apps/new.app"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sorted = LauncherFrecency.sorted([old, new, frequent], counts: [old.id: 1000, frequent.id: 10],
                                             lastUsed: [
                                                 old.id: now.addingTimeInterval(-180 * 86400).timeIntervalSince1970,
                                                 frequent.id: now.timeIntervalSince1970,
                                             ], now: now)
        #expect(sorted == [frequent, old, new])
        #expect(LauncherFrecency.sorted([new, old], counts: [:], lastUsed: [:], now: now) == [new, old])
    }
}
