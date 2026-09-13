import Foundation
@testable import OverboardCore
import Testing

/// Counts job runs across the scheduler's background tasks.
private actor RunCounter {
    private(set) var count = 0

    func bump() {
        self.count += 1
    }

    /// Waits until `count >= target`, or gives up after `timeout`. Polling
    /// keeps these tests off wall-clock sleeps long enough to be flaky.
    func wait(for target: Int, timeout: Duration = .seconds(5)) async -> Int {
        let deadline = ContinuousClock.now + timeout
        while self.count < target, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return self.count
    }
}

/// Builds a job at `.userInitiated` priority. The production default is
/// `.background`, which macOS throttles hard under load — a parallel
/// `swift build` was enough to keep a job from running before `wait(for:)`
/// gave up. Every test goes through here so scheduling order, not QoS, is
/// what's under test.
private func testJob(
    name: String,
    interval: Duration,
    initialDelay: Duration = .zero,
    work: @escaping @Sendable () async -> MaintenanceJob.Outcome
) -> MaintenanceJob {
    MaintenanceJob(
        name: name,
        interval: interval,
        initialDelay: initialDelay,
        priority: .userInitiated,
        work: work
    )
}

@Suite(.timeLimit(.minutes(1)))
struct MaintenanceSchedulerTests {
    @Test func runsAJobImmediatelyWhenThereIsNoInitialDelay() async {
        let counter = RunCounter()
        let scheduler = MaintenanceScheduler(jobs: [
            testJob(name: "once", interval: .seconds(3600)) {
                await counter.bump()
                return .repeatLater
            },
        ])
        scheduler.start()
        defer { scheduler.stop() }

        #expect(await counter.wait(for: 1) >= 1)
    }

    @Test func repeatsOnItsInterval() async {
        let counter = RunCounter()
        let scheduler = MaintenanceScheduler(jobs: [
            testJob(name: "ticker", interval: .milliseconds(10)) {
                await counter.bump()
                return .repeatLater
            },
        ])
        scheduler.start()
        defer { scheduler.stop() }

        #expect(await counter.wait(for: 3) >= 3)
    }

    @Test func startsEveryJob() async {
        let first = RunCounter()
        let second = RunCounter()
        let scheduler = MaintenanceScheduler(jobs: [
            testJob(name: "a", interval: .seconds(3600)) {
                await first.bump()
                return .repeatLater
            },
            testJob(name: "b", interval: .seconds(3600)) {
                await second.bump()
                return .repeatLater
            },
        ])
        scheduler.start()
        defer { scheduler.stop() }

        #expect(await first.wait(for: 1) >= 1)
        #expect(await second.wait(for: 1) >= 1)
    }

    @Test func aSecondStartDoesNotDoubleUpTheLoops() async throws {
        let counter = RunCounter()
        let scheduler = MaintenanceScheduler(jobs: [
            testJob(name: "once", interval: .seconds(3600)) {
                await counter.bump()
                return .repeatLater
            },
        ])
        scheduler.start()
        #expect(await counter.wait(for: 1) >= 1)
        scheduler.start()
        defer { scheduler.stop() }

        // One long-interval job, started twice: still exactly one run.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await counter.count == 1)
    }

    @Test func stopCancelsTheLoop() async throws {
        let counter = RunCounter()
        let scheduler = MaintenanceScheduler(jobs: [
            testJob(name: "ticker", interval: .milliseconds(5)) {
                await counter.bump()
                return .repeatLater
            },
        ])
        scheduler.start()
        #expect(await counter.wait(for: 2) >= 2)

        scheduler.stop()
        // A cancelled sleep returns immediately, so let the loop notice, then
        // confirm the count has settled.
        try await Task.sleep(for: .milliseconds(50))
        let settled = await counter.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(await counter.count == settled)
    }

    @Test func aFinishedJobStopsRescheduling() async throws {
        let counter = RunCounter()
        let scheduler = MaintenanceScheduler(jobs: [
            // The link-backfill shape: drain, then stop until next launch.
            testJob(name: "drain", interval: .milliseconds(1)) {
                await counter.bump()
                return .finished
            },
        ])
        scheduler.start()
        defer { scheduler.stop() }

        #expect(await counter.wait(for: 1) >= 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await counter.count == 1)
    }

    @Test func initialDelayHoldsTheFirstRunBack() async throws {
        let counter = RunCounter()
        let scheduler = MaintenanceScheduler(jobs: [
            testJob(
                name: "delayed",
                interval: .milliseconds(5),
                initialDelay: .seconds(30)
            ) {
                await counter.bump()
                return .repeatLater
            },
        ])
        scheduler.start()
        defer { scheduler.stop() }

        try await Task.sleep(for: .milliseconds(50))
        #expect(await counter.count == 0)
    }

    @Test func stopBeforeStartIsHarmlessAndRestartWorks() async {
        let counter = RunCounter()
        let scheduler = MaintenanceScheduler(jobs: [
            testJob(name: "once", interval: .seconds(3600)) {
                await counter.bump()
                return .repeatLater
            },
        ])
        scheduler.stop()
        scheduler.start()
        #expect(await counter.wait(for: 1) >= 1)
        scheduler.stop()
        scheduler.start()
        defer { scheduler.stop() }
        #expect(await counter.wait(for: 2) >= 2)
    }
}
