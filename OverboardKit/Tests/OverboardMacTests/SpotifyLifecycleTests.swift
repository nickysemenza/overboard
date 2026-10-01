import Foundation
import OverboardCore
@testable import OverboardMac
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SpotifyLifecycleTests {
    private let oldLine = "Playing\tOld\tArtist\tspotify:track:old"
    private let newLine = "Playing\tNew\tArtist\tspotify:track:new"

    @Test func playbackNotificationInvalidatesOlderSnapshot() async {
        let gate = LifecycleReadGate<String?>()
        let monitor = SpotifyNowPlayingMonitor(applicationIsRunning: { true }, readSnapshot: { await gate.read() })
        monitor.start()
        defer { monitor.stop() }
        await gate.waitForReads(1)
        let oldTask = monitor.snapshotTask
        monitor.receivedPlayback(NowPlayingTrack.parse(snapshotLine: self.newLine))
        await gate.release(returning: self.oldLine)
        await oldTask?.value
        #expect(monitor.current?.title == "New")
    }

    @Test func quitInvalidatesSnapshotEvenWithoutStoppedBroadcast() async {
        let gate = LifecycleReadGate<String?>()
        let monitor = SpotifyNowPlayingMonitor(applicationIsRunning: { true }, readSnapshot: { await gate.read() })
        monitor.start()
        defer { monitor.stop() }
        await gate.waitForReads(1)
        let oldTask = monitor.snapshotTask
        monitor.receivedPlayback(NowPlayingTrack.parse(snapshotLine: self.newLine))
        monitor.applicationTerminated()
        await gate.release(returning: self.oldLine)
        await oldTask?.value
        #expect(monitor.current == nil)
    }

    @Test func newerSnapshotWinsWhenOlderRequestCompletesLast() async {
        let gate = LifecycleReadGate<String?>()
        let clock = LifecycleTestClock()
        let monitor = SpotifyNowPlayingMonitor(
            applicationIsRunning: { true }, readSnapshot: { await gate.read() }, now: { clock.now }
        )
        monitor.start()
        defer { monitor.stop() }
        await gate.waitForReads(1)
        let oldTask = monitor.snapshotTask
        clock.advance()
        monitor.refreshSnapshot()
        await gate.waitForReads(2)
        let newTask = monitor.snapshotTask
        await gate.release(2, returning: self.newLine)
        await newTask?.value
        await gate.release(returning: self.oldLine)
        await oldTask?.value
        #expect(monitor.current?.title == "New")
    }

    @Test func restartRejectsOldSnapshot() async {
        let gate = LifecycleReadGate<String?>()
        let monitor = SpotifyNowPlayingMonitor(applicationIsRunning: { true }, readSnapshot: { await gate.read() })
        monitor.start()
        defer { monitor.stop() }
        await gate.waitForReads(1)
        let oldTask = monitor.snapshotTask
        monitor.stop()
        monitor.start()
        await gate.waitForReads(2)
        let newTask = monitor.snapshotTask
        await gate.release(2, returning: self.newLine)
        await newTask?.value
        await gate.release(returning: self.oldLine)
        await oldTask?.value
        #expect(monitor.current?.title == "New")
    }

    @Test func missingApplicationClearsSnapshotAtCompletion() async {
        let gate = LifecycleReadGate<String?>()
        var running = true
        let monitor = SpotifyNowPlayingMonitor(applicationIsRunning: { running }, readSnapshot: { await gate.read() })
        monitor.start()
        defer { monitor.stop() }
        await gate.waitForReads(1)
        let oldTask = monitor.snapshotTask
        running = false
        await gate.release(returning: self.oldLine)
        await oldTask?.value
        #expect(monitor.current == nil)
    }
}
