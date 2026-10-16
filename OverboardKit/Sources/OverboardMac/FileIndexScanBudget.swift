import Foundation

/// A wall-time work slice, not a CPU guarantee: provider waits count toward
/// the slice too. Keeps long discovery/recovery scans from running nonstop.
nonisolated struct FileIndexScanBudget {
    private var start = ContinuousClock.now

    mutating func yieldIfNeeded() async throws {
        guard self.start.duration(to: .now) >= .milliseconds(20) else { return }
        try await Task.sleep(for: .milliseconds(80))
        self.start = .now
    }
}
