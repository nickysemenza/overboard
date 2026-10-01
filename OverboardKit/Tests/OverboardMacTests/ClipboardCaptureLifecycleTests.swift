import AppKit
import OverboardCore
@testable import OverboardMac
import Testing

@MainActor
struct ClipboardCaptureLifecycleTests {
    @Test func stopInvalidatesBufferedSnapshotsAndResumeUsesNewAdmission() throws {
        let board = NSPasteboard(name: .init("capture-lifecycle-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: board)
        monitor.start()
        defer { monitor.stop() }
        board.clearContents()
        board.setString("old snapshot", forType: .string)
        let original = try #require(monitor.capturePendingSnapshot())
        let oldAdmission = try #require(original.admission)
        monitor.stop()
        #expect(throws: CancellationError.self) { try oldAdmission.check() }
        board.clearContents()
        board.setString("while paused", forType: .string)
        #expect(monitor.capturePendingSnapshot() == nil)
        monitor.start()
        #expect(monitor.capturePendingSnapshot() == nil)
        board.clearContents()
        board.setString("resumed snapshot", forType: .string)
        let resumed = try #require(monitor.capturePendingSnapshot())
        let resumedAdmission = try #require(resumed.admission)
        try resumedAdmission.check()
        #expect(resumedAdmission != oldAdmission)
        #expect(throws: CancellationError.self) { try oldAdmission.check() }
    }
}
