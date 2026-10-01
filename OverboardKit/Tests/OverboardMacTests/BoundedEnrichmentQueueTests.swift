import Foundation
import OverboardCore
@testable import OverboardMac
import Testing

@MainActor
struct BoundedEnrichmentQueueTests {
    @Test func disabledQueueRejectsWorkAndBoundsPendingBytesAndCount() {
        let queue = BoundedEnrichmentQueue(capacity: 2, byteLimit: 8) { _, _ in }
        let snapshot = PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data("four".utf8))],
            sourceBundleID: nil, sourceAppName: nil
        )
        let item = self.item()
        #expect(!queue.enqueue(item: item, snapshot: snapshot))
        queue.start()
        for _ in 0 ..< 10 {
            #expect(queue.enqueue(item: item, snapshot: snapshot))
        }
        #expect(queue.pendingCount == 2)
        #expect(queue.retainedBytes == 8)
        var oversized = snapshot
        oversized.reps[0].data = Data(repeating: 0, count: 9)
        #expect(!queue.enqueue(item: item, snapshot: oversized))
        queue.stop()
        #expect(!queue.isRunning)
        #expect(queue.pendingCount == 0)
        #expect(queue.retainedBytes == 0)
    }

    @Test func stoppingCancelsOwnedWorkAndDropsPendingPublication() async {
        let recorder = EnrichmentQueueRecorder()
        let queue = BoundedEnrichmentQueue { _, _ in
            await recorder.started()
            do {
                try await Task.sleep(for: .seconds(60))
                await recorder.published()
            } catch {
                await recorder.cancelled()
            }
        }
        let snapshot = PasteboardSnapshot(reps: [], sourceBundleID: nil, sourceAppName: nil)
        queue.start()
        queue.enqueue(item: self.item(), snapshot: snapshot)
        await recorder.waitForStart()
        queue.enqueue(item: self.item(), snapshot: snapshot)
        queue.stop()
        await recorder.waitForCancellation()
        #expect(await recorder.publications == 0)
        #expect(queue.pendingCount == 0)
    }

    @Test func restartingWaitsForCancelledWorkToRetireAndIncludesActiveBytes() async {
        let recorder = UncancellableEnrichmentRecorder()
        let queue = BoundedEnrichmentQueue(byteLimit: 8) { _, _ in await recorder.process() }
        let snapshot = PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data("four".utf8))],
            sourceBundleID: nil, sourceAppName: nil
        )
        queue.start()
        queue.enqueue(item: self.item(), snapshot: snapshot)
        await recorder.waitForInvocations(1)
        queue.stop()
        queue.start()
        #expect(queue.enqueue(item: self.item(), snapshot: snapshot))
        #expect(queue.retainedBytes == 8)
        var oversized = snapshot
        oversized.reps[0].data = Data(repeating: 0, count: 5)
        #expect(!queue.enqueue(item: self.item(), snapshot: oversized))
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(await recorder.invocations == 1)
        await recorder.release()
        await recorder.waitForInvocations(2)
        #expect(await recorder.maximumActive == 1)
        queue.stop()
    }

    private func item() -> ClipItem {
        ClipItem(
            contentHash: "queue", kind: .text, previewText: nil, sourceBundleID: nil, sourceAppName: nil,
            byteSize: 4, createdAt: Date(), lastUsedAt: Date(), updatedAt: Date()
        )
    }
}

private actor UncancellableEnrichmentRecorder {
    var invocations = 0
    var maximumActive = 0
    private var active = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func process() async {
        self.invocations += 1
        self.active += 1
        self.maximumActive = max(self.maximumActive, self.active)
        if self.invocations == 1 {
            await withCheckedContinuation { self.continuation = $0 }
        }
        self.active -= 1
    }

    func release() {
        self.continuation?.resume()
        self.continuation = nil
    }

    func waitForInvocations(_ count: Int) async {
        while self.invocations < count {
            await Task.yield()
        }
    }
}

private actor EnrichmentQueueRecorder {
    var publications = 0
    private var hasStarted = false
    private var hasCancelled = false

    func started() {
        self.hasStarted = true
    }

    func cancelled() {
        self.hasCancelled = true
    }

    func published() {
        self.publications += 1
    }

    func waitForStart() async {
        while !self.hasStarted {
            await Task.yield()
        }
    }

    func waitForCancellation() async {
        while !self.hasCancelled {
            await Task.yield()
        }
    }
}
