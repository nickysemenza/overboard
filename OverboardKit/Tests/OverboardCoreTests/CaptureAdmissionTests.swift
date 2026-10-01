import Foundation
import GRDB
@testable import OverboardCore
import Testing

struct CaptureAdmissionTests {
    @Test func obsoleteBufferedCaptureCannotPersistAfterResume() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipStore(dbWriter: OverboardDatabase.openInMemory(), blobs: BlobStore(directory: directory))
        let oldSession = CaptureAdmission()
        let obsolete = self.snapshot("old generation", admission: oldSession)
        oldSession.invalidate()
        let current = self.snapshot("current generation", admission: CaptureAdmission())
        await #expect(throws: CancellationError.self) { try await store.ingest(obsolete) }
        _ = try await store.ingest(current)
        #expect(try await store.recent().map(\.previewText) == ["current generation"])
    }

    @Test func invalidatingQueuedCaptureRejectsDatabasePublication() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try OverboardDatabase.open(at: directory)
        let store = try ClipStore(
            dbWriter: database,
            blobs: BlobStore(directory: directory.appendingPathComponent("blobs"))
        )
        let admission = CaptureAdmission()
        let writerEntered = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let blocker = Task.detached {
            try await database.write { _ in
                writerEntered.signal()
                releaseWriter.wait()
            }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                writerEntered.wait()
                continuation.resume()
            }
        }
        let capture = Task { try await store.ingest(self.snapshot("queued", admission: admission)) }
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        admission.invalidate()
        releaseWriter.signal()
        try await blocker.value
        await #expect(throws: CancellationError.self) { try await capture.value }
        #expect(try await store.recent().isEmpty)
    }

    @Test func cancelledCaptureCannotEnterPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipStore(dbWriter: OverboardDatabase.openInMemory(), blobs: BlobStore(directory: directory))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.ingest(self.snapshot("cancelled", admission: CaptureAdmission()))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.recent().isEmpty)
    }

    @Test func invalidationInsideWriteRollsBackRowsAndIndexes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try OverboardDatabase.openInMemory()
        let store = try ClipStore(dbWriter: database, blobs: BlobStore(directory: directory))
        let admission = CaptureAdmission()
        try await database.write { database in
            database.add(function: DatabaseFunction("invalidateCapture", argumentCount: 0) { _ in
                admission.invalidate()
                return 1
            })
            try database.execute(sql: """
            CREATE TRIGGER cancel_capture AFTER INSERT ON item BEGIN SELECT invalidateCapture(); END
            """)
        }
        await #expect(throws: CancellationError.self) {
            try await store.ingest(self.snapshot("cancel during write", admission: admission))
        }
        #expect(try await store.recent().isEmpty)
        #expect(try await store.search("cancel").isEmpty)
        let representations = try await database
            .read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM representation") }
        #expect(representations == 0)
    }

    private func snapshot(_ text: String, admission: CaptureAdmission) -> PasteboardSnapshot {
        PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data(text.utf8))],
            sourceBundleID: nil, sourceAppName: nil, admission: admission
        )
    }
}
