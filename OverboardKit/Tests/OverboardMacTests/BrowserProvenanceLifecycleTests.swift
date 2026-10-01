@testable import OverboardMac
import Testing

@Suite(.timeLimit(.minutes(1)))
struct BrowserProvenanceLifecycleTests {
    @Test func timeoutReturnsBeforeUncancellableScriptRetires() async throws {
        let gate = LifecycleReadGate<String?>()
        let fetch = Task {
            await BrowserProvenanceService.fetch(timeout: .milliseconds(20)) { await gate.read() }
        }
        await gate.waitForReads(1)
        let retirement = Task {
            try await Task.sleep(for: .milliseconds(300))
            await gate.release(returning: "https://example.com\tLate")
        }
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await fetch.value == nil)
        #expect(start.duration(to: clock.now) < .milliseconds(200))
        try await retirement.value
    }

    @Test func cancellationReturnsBeforeUncancellableScriptRetires() async throws {
        let gate = LifecycleReadGate<String?>()
        let fetch = Task {
            await BrowserProvenanceService.fetch(timeout: .seconds(10)) { await gate.read() }
        }
        await gate.waitForReads(1)
        let retirement = Task {
            try await Task.sleep(for: .milliseconds(300))
            await gate.release(returning: "https://example.com\tLate")
        }
        let clock = ContinuousClock()
        let start = clock.now
        fetch.cancel()
        #expect(await fetch.value == nil)
        #expect(start.duration(to: clock.now) < .milliseconds(200))
        try await retirement.value
    }

    @Test func immediateScriptCompletesAndCancelsDeadline() async {
        let result = await BrowserProvenanceService.fetch(timeout: .seconds(10)) {
            "https://example.com\tCurrent"
        }
        #expect(result?.url == "https://example.com")
        #expect(result?.title == "Current")
    }
}
