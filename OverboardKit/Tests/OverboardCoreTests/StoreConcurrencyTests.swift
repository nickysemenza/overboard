import Foundation
import GRDB
@testable import OverboardCore
import Testing

/// Guards the property that made `ClipStore`'s GRDB calls async: a read must not
/// have to wait for an unrelated write to finish.
struct StoreConcurrencyTests {
    private func textSnapshot(_ text: String) -> PasteboardSnapshot {
        PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data(text.utf8))],
            sourceBundleID: "com.apple.TextEdit",
            sourceAppName: "TextEdit"
        )
    }

    /// `ClipStore` used to call `dbWriter.write` *synchronously* from inside the
    /// actor, which pinned the actor's executor for the whole write. An `ingest`
    /// stuck behind a busy writer therefore blocked every other caller — a
    /// keystroke's `recent()` queued behind it even though `DatabasePool` could
    /// have answered it from a WAL reader straight away.
    ///
    /// The test holds the pool's single writer with a sleeping write, starts an
    /// `ingest` that must queue behind it, and then times `recent()`. Under the
    /// old shape `recent()` took as long as the blocker (it could not enter the
    /// actor); now it returns immediately. On-disk `DatabasePool` on purpose:
    /// `openInMemory()` hands back a `DatabaseQueue`, where reads and writes
    /// share one connection and this concurrency does not exist.
    @Test func readsDoNotQueueBehindAWrite() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-concurrency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pool = try OverboardDatabase.open(at: directory)
        let blobs = try BlobStore(directory: directory.appendingPathComponent("blobs", isDirectory: true))
        let store = ClipStore(dbWriter: pool, blobs: blobs)

        try await store.ingest(self.textSnapshot("seed"))
        // Warm a reader connection so the measurement below is the query, not
        // the pool opening its first reader.
        _ = try await store.recent(limit: 1)

        let blockedFor = Duration.milliseconds(600)
        let blocker = Task.detached {
            try await pool.write { _ in
                Thread.sleep(forTimeInterval: 0.6)
            }
        }
        try await Task.sleep(for: .milliseconds(50)) // let the blocker take the writer
        let queuedWrite = Task { try await store.ingest(self.textSnapshot("queued behind the writer")) }
        try await Task.sleep(for: .milliseconds(50)) // let the ingest reach the writer queue

        let start = ContinuousClock.now
        let items = try await store.recent(limit: 10)
        let elapsed = ContinuousClock.now - start

        #expect(!items.isEmpty)
        #expect(
            elapsed < blockedFor / 3,
            "recent() took \(elapsed) while a write held the writer — it queued behind it"
        )

        // Both writes still land, in writer order.
        _ = try await queuedWrite.value
        try await blocker.value
        #expect(try await store.recent(limit: 10).count == 2)
    }
}
