import Foundation
import OverboardCore
@testable import OverboardMac
import Testing

@MainActor
struct FileIndexLossRecoveryTests {
    @Test func repeatedDropsPostponeRecoveryButNotPastTheDeadline() throws {
        let service = try FileIndexService(
            index: FileNameIndex(), roots: [URL(fileURLWithPath: "/fixture", isDirectory: true)], operations: .init()
        )
        let first = ContinuousClock.now
        service.scheduleLossRecovery(now: first)
        let initial = try #require(service.refreshTask)
        service.scheduleLossRecovery(now: first + .seconds(20))
        let postponed = try #require(service.refreshTask)
        #expect(postponed != initial)
        #expect(initial.isCancelled)
        service.scheduleLossRecovery(now: first + FileIndexService.lossMaximumDelay)
        #expect(service.refreshTask == postponed, "a burst past the deadline must not push the rescan back again")
        #expect(service.pendingLossSince == first)
        service.stop()
    }
}
