import Foundation
import os

/// One recurring background chore: history purge, secret expiry, blob/VACUUM
/// sweep, link backfill. Each was its own hand-rolled
/// `while !Task.isCancelled { work; try? await Task.sleep(...) }` loop before;
/// this is the shape they all shared.
public struct MaintenanceJob: Sendable {
    /// What one run says about whether the job should run again. Most jobs
    /// always reschedule; a drain-style job (link backfill) reports `.finished`
    /// when there's nothing left to do and isn't started again until relaunch.
    public enum Outcome: Sendable {
        case repeatLater
        case finished
    }

    /// Identifies the job in log output.
    public let name: String
    /// Delay between the end of one run and the start of the next.
    public let interval: Duration
    /// Delay before the first run. `.zero` means "run at start" — the others
    /// stagger themselves so a launch isn't a stampede of disk and network.
    public let initialDelay: Duration
    public let priority: TaskPriority
    public let work: @Sendable () async -> Outcome

    public init(
        name: String,
        interval: Duration,
        initialDelay: Duration = .zero,
        priority: TaskPriority = .background,
        work: @escaping @Sendable () async -> Outcome
    ) {
        self.name = name
        self.interval = interval
        self.initialDelay = initialDelay
        self.priority = priority
        self.work = work
    }
}

/// Owns the app's recurring background jobs as one unit, so the composition
/// root starts and cancels them with a single call instead of tracking a task
/// property per chore.
///
/// Deliberately not `Sendable`: it's created and driven from the main actor
/// (app launch and termination), and the work it schedules is `@Sendable` on
/// its own. Cancellation is cooperative — a job stops at its next `await`.
public final class MaintenanceScheduler {
    private let jobs: [MaintenanceJob]
    private var tasks: [Task<Void, Never>] = []
    private let logger = Logger(subsystem: "com.nickysemenza.overboard", category: "maintenance")

    public init(jobs: [MaintenanceJob]) {
        self.jobs = jobs
    }

    /// Starts every job. Idempotent — calling it while already running is a
    /// no-op rather than a second set of loops.
    public func start() {
        guard self.tasks.isEmpty else { return }
        self.tasks = self.jobs.map { job in
            Task(priority: job.priority) { [logger] in
                if job.initialDelay > .zero {
                    try? await Task.sleep(for: job.initialDelay)
                }
                while !Task.isCancelled {
                    guard await job.work() == .repeatLater else {
                        logger.debug("maintenance job \(job.name, privacy: .public) finished")
                        return
                    }
                    try? await Task.sleep(for: job.interval)
                }
            }
        }
    }

    /// Cancels every running job. Safe to call when not started, and a
    /// subsequent `start()` begins a fresh set of loops.
    public func stop() {
        for task in self.tasks {
            task.cancel()
        }
        self.tasks.removeAll()
    }

    deinit {
        for task in self.tasks {
            task.cancel()
        }
    }
}
