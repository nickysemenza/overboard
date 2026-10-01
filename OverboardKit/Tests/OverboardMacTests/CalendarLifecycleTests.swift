import Foundation
import OverboardCore
@testable import OverboardMac
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CalendarLifecycleTests {
    private func events(_ title: String) -> [CalendarEvent] {
        [CalendarEvent(eventIdentifier: title, title: title, start: .now, end: .now.addingTimeInterval(3600))]
    }

    @Test func cooldownCoalescesChangesAndRunsTrailingRefresh() async {
        let gate = LifecycleReadGate<[CalendarEvent]>()
        let sleeps = LifecycleReadGate<Void>()
        let clock = LifecycleTestClock()
        let source = CalendarSource(
            access: { .granted }, readEvents: { _, _ in await gate.read() }, now: { clock.now },
            sleep: { _ in await sleeps.read() }
        )
        source.start()
        defer { source.stop() }
        await gate.waitForReads(1)
        let initial = source.fetchTask
        await gate.release(returning: self.events("Initial"))
        await initial?.value
        clock.advance(0.2)
        for _ in 0 ..< 10 {
            source.refreshSnapshot()
        }
        await sleeps.waitForReads(1)
        #expect(await gate.count == 1)
        let cooldown = source.cooldownTask
        clock.advance()
        await sleeps.release(returning: ())
        await cooldown?.value
        await gate.waitForReads(2)
        let trailing = source.fetchTask
        await gate.release(2, returning: self.events("Trailing"))
        await trailing?.value
        #expect(source.upcomingEvents.first?.title == "Trailing")
        #expect(await gate.count == 2)
        #expect(await sleeps.count == 1)
    }

    @Test func revocationClearsCachedEventsBeforeCooldownCheck() async {
        let gate = LifecycleReadGate<[CalendarEvent]>()
        let clock = LifecycleTestClock()
        var access = PermissionState.granted
        let source = CalendarSource(
            access: { access }, readEvents: { _, _ in await gate.read() }, now: { clock.now }
        )
        source.start()
        defer { source.stop() }
        await gate.waitForReads(1)
        let initial = source.fetchTask
        await gate.release(returning: self.events("Cached"))
        await initial?.value
        clock.advance(0.1)
        access = .denied
        source.refreshSnapshot()
        #expect(source.upcomingEvents.isEmpty)
        #expect(source.snapshot.withLock { $0.isEmpty })
        #expect(await gate.count == 1)
    }

    @Test func revocationAtFetchCompletionClearsPreviousSnapshot() async {
        let gate = LifecycleReadGate<[CalendarEvent]>()
        let clock = LifecycleTestClock()
        var access = PermissionState.granted
        let source = CalendarSource(
            access: { access }, readEvents: { _, _ in await gate.read() }, now: { clock.now }
        )
        source.start()
        defer { source.stop() }
        await gate.waitForReads(1)
        let initial = source.fetchTask
        await gate.release(returning: self.events("Cached"))
        await initial?.value
        clock.advance()
        source.refreshSnapshot()
        await gate.waitForReads(2)
        let refresh = source.fetchTask
        access = .denied
        await gate.release(2, returning: self.events("Obsolete"))
        await refresh?.value
        #expect(source.upcomingEvents.isEmpty)
        #expect(source.snapshot.withLock { $0.isEmpty })
    }

    @Test func restartWaitsForUncancellableFetchAndRejectsOldPublication() async {
        let gate = LifecycleReadGate<[CalendarEvent]>()
        let source = CalendarSource(access: { .granted }, readEvents: { _, _ in await gate.read() })
        var publications: [[CalendarEvent]] = []
        source.onChange = { publications.append(source.upcomingEvents) }
        source.start()
        defer { source.stop() }
        await gate.waitForReads(1)
        let oldTask = source.fetchTask
        source.stop()
        source.start()
        #expect(await gate.count == 1)
        await gate.release(returning: self.events("Obsolete"))
        await oldTask?.value
        await gate.waitForReads(2)
        #expect(source.upcomingEvents.isEmpty)
        let newTask = source.fetchTask
        await gate.release(2, returning: self.events("Current"))
        await newTask?.value
        #expect(publications.count == 1)
        #expect(source.upcomingEvents.first?.title == "Current")
    }

    @Test func stoppedCooldownCannotStartAnotherFetch() async {
        let gate = LifecycleReadGate<[CalendarEvent]>()
        let sleeps = LifecycleReadGate<Void>()
        let clock = LifecycleTestClock()
        let source = CalendarSource(
            access: { .granted }, readEvents: { _, _ in await gate.read() }, now: { clock.now },
            sleep: { _ in await sleeps.read() }
        )
        source.start()
        await gate.waitForReads(1)
        let initial = source.fetchTask
        await gate.release(returning: self.events("Cached"))
        await initial?.value
        source.refreshSnapshot()
        await sleeps.waitForReads(1)
        let cooldown = source.cooldownTask
        source.stop()
        clock.advance()
        await sleeps.release(returning: ())
        await cooldown?.value
        #expect(await gate.count == 1)
        #expect(source.upcomingEvents.isEmpty)
    }
}
