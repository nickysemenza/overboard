import Foundation
import GRDB
@testable import OverboardCore
import Synchronization
import Testing

private enum ArchiveLifecycleFailure: Error {
    case timedOut
}

private final class ArchiveLifecycleGate: Sendable {
    private let entered = Mutex(false)
    private let timeout = Mutex(false)
    private let releaseSignal = DispatchSemaphore(value: 0)
    private let arrivals: AsyncStream<Void>
    private let arrival: AsyncStream<Void>.Continuation

    init() {
        let stream = AsyncStream<Void>.makeStream()
        self.arrivals = stream.stream
        self.arrival = stream.continuation
    }

    func pause() {
        let first = self.entered.withLock { entered in
            if entered {
                return false
            }
            entered = true
            return true
        }
        guard first else { return }
        self.arrival.yield(())
        if self.releaseSignal.wait(timeout: .now() + 10) != .success {
            self.timeout.withLock { $0 = true }
        }
    }

    func waitUntilPaused() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in self.arrivals {
                    return
                }
                throw ArchiveLifecycleFailure.timedOut
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw ArchiveLifecycleFailure.timedOut
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    func release() {
        self.releaseSignal.signal()
    }

    var timedOut: Bool {
        self.timeout.withLock { $0 }
    }
}

private struct ArchiveLifecycleHarness: Sendable {
    let root: URL
    let database: any DatabaseWriter
    let blobs: BlobStore
    let store: ClipStore

    init(pool: Bool = false) throws {
        self.root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("archive-lifecycle-\(UUID().uuidString)")
        self.blobs = try BlobStore(directory: self.root.appendingPathComponent("managed-blobs"))
        self.database = try pool
            ? OverboardDatabase.open(at: self.root.appendingPathComponent("database"))
            : OverboardDatabase.openInMemory()
        self.store = ClipStore(dbWriter: self.database, blobs: self.blobs)
    }

    var archive: URL {
        self.root.appendingPathComponent("archive")
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.root)
    }

    @discardableResult
    func image(_ byte: UInt8) async throws -> ArchiveImageFixture {
        let bytes = Data(repeating: byte, count: Representation.inlineThreshold + 17)
        let item = try #require(await self.store.ingest(.init(
            reps: [.init(uti: WellKnownUTI.png, data: bytes)], sourceBundleID: nil, sourceAppName: nil
        )))
        return ArchiveImageFixture(item: item, hash: BlobStore.hash(bytes), bytes: bytes)
    }

    func archiveBytes() throws -> [String: Data] {
        let names = try [ClipArchive.itemsFileName, ClipArchive.snippetsFileName, ClipArchive.manifestFileName]
            + (FileManager.default.contentsOfDirectory(atPath: self.archive.appendingPathComponent("blobs").path))
            .map { "blobs/\($0)" }
        return try Dictionary(uniqueKeysWithValues: names.map {
            try ($0, Data(contentsOf: self.archive.appendingPathComponent($0)))
        })
    }

    func expectNoExportStaging() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: self.root.path)
        #expect(!names.contains { $0.hasPrefix(".overboard-archive-") })
    }

    func pauseSnapshot(at gate: ArchiveLifecycleGate) async throws {
        try await self.pauseStatement("SELECT * FROM representation WHERE itemID", at: gate)
    }

    func pauseStatement(_ prefix: String, at gate: ArchiveLifecycleGate) async throws {
        try await self.database.write { database in
            database.trace { event in
                guard case let .statement(statement) = event, statement.sql.hasPrefix(prefix) else { return }
                gate.pause()
            }
        }
    }
}

struct ArchiveLifecycleTests {
    @Test func cancellationBeforeImportRejectsBeforeReadingArchiveOrMutatingDatabase() async throws {
        let destination = try ArchiveLifecycleHarness()
        defer { destination.remove() }
        let kept = try await destination.image(0x11)
        let missingArchive = destination.root.appendingPathComponent("must-not-be-read")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await destination.store.import(from: missingArchive)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await destination.store.recent().map(\.id) == [kept.item.id])
        #expect(try destination.blobs.data(for: kept.hash) == kept.bytes)
        #expect(!FileManager.default.fileExists(atPath: missingArchive.path))
        try destination.expectNoExportStaging()
    }

    @Test func cancellationBeforeExportPreservesPreviousGoodArchiveAndRemovesNoPayloads() async throws {
        let source = try ArchiveLifecycleHarness()
        defer { source.remove() }
        let kept = try await source.image(0x21)
        try await source.store.export(to: source.archive)
        let previous = try source.archiveBytes()
        try await source.image(0x22)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await source.store.export(to: source.archive)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try source.archiveBytes() == previous)
        #expect(try source.blobs.data(for: kept.hash) == kept.bytes)
        #expect(try await source.store.recent().count == 2)
        try source.expectNoExportStaging()
    }

    @Test func cancellationDuringImportSettingsValidationNeverStartsDatabaseMutation() async throws {
        let source = try ArchiveLifecycleHarness()
        let destination = try ArchiveLifecycleHarness()
        defer { source.remove(); destination.remove() }
        try await source.image(0x31)
        try await source.store.export(to: source.archive)
        let kept = try await destination.image(0x32)
        let validated = Mutex(false)
        let task = Task {
            try await destination.store.import(from: source.archive, validateSettings: { _ in
                validated.withLock { $0 = true }
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(validated.withLock { $0 })
        #expect(try await destination.store.recent().map(\.id) == [kept.item.id])
        #expect(try await destination.store.snippets().isEmpty)
    }

    @Test func cancellationDuringImportRollsBackItemsRepresentationsPinMergeAndSnippets() async throws {
        let source = try ArchiveLifecycleHarness()
        let destination = try ArchiveLifecycleHarness()
        defer { source.remove(); destination.remove() }
        let shared = try await source.image(0x41)
        try await source.store.setPinned(id: shared.item.id, true)
        let added = try await source.image(0x42)
        try await source.store.saveSnippet(.init(id: "cancelled-snippet", title: "New", body: "Synthetic body"))
        try await source.store.export(to: source.archive)
        let kept = try await destination.image(0x41)
        try await destination.store.saveSnippet(.init(id: "kept-snippet", title: "Kept", body: "Retained body"))
        let gate = ArchiveLifecycleGate()
        try await destination.database.write { database in
            database.add(function: DatabaseFunction("archive_lifecycle_pause", argumentCount: 0) { _ in
                gate.pause()
                return 0
            })
            try database.execute(sql: """
            CREATE TEMP TRIGGER pause_archive_snippet AFTER INSERT ON snippet
            WHEN NEW.id = 'cancelled-snippet'
            BEGIN SELECT archive_lifecycle_pause(); END
            """)
        }
        let task = Task { try await destination.store.import(from: source.archive) }
        defer { task.cancel(); gate.release() }
        try await gate.waitUntilPaused()
        task.cancel()
        gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!gate.timedOut)
        let remaining = try await destination.store.recent()
        #expect(remaining.map(\.id) == [kept.item.id])
        #expect(remaining.first?.isPinned == false)
        #expect(try await destination.store.representations(for: kept.item.id).count == 1)
        #expect(try await destination.store.representations(for: added.item.id).isEmpty)
        #expect(try await destination.store.snippets().map(\.id) == ["kept-snippet"])
        #expect(try destination.blobs.data(for: kept.hash) == kept.bytes)
    }

    @Test func cancellationDuringExportSnapshotPreservesPreviousGoodArchiveAndCleansStaging() async throws {
        let source = try ArchiveLifecycleHarness()
        defer { source.remove() }
        try await source.image(0x51)
        try await source.store.export(to: source.archive)
        let previous = try source.archiveBytes()
        try await source.image(0x52)
        let gate = ArchiveLifecycleGate()
        try await source.pauseSnapshot(at: gate)
        let task = Task { try await source.store.export(to: source.archive) }
        defer { task.cancel(); gate.release() }
        try await gate.waitUntilPaused()
        task.cancel()
        gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!gate.timedOut)
        #expect(try source.archiveBytes() == previous)
        #expect(try await source.store.recent().count == 2)
        try source.expectNoExportStaging()
    }

    @Test func cancellationImmediatelyBeforeAtomicPublicationPreservesPreviousGoodArchive() async throws {
        let source = try ArchiveLifecycleHarness()
        defer { source.remove() }
        try await source.image(0x61)
        try await source.store.export(to: source.archive)
        let previous = try source.archiveBytes()
        try await source.image(0x62)
        let reachedPublication = Mutex(false)
        let task = Task {
            try await source.store.exportArchive(
                to: source.archive, includeSecrets: false, settings: nil, limits: .init(),
                publish: { staged, destination in
                    let data = try Data(contentsOf: staged.appendingPathComponent(ClipArchive.manifestFileName))
                    let manifest = try ClipJSONCoding.archiveDecoder().decode(ClipArchive.Manifest.self, from: data)
                    #expect(manifest.itemCount == 2)
                    reachedPublication.withLock { $0 = true }
                    withUnsafeCurrentTask { $0?.cancel() }
                    try ArchiveIO.publish(staged, to: destination)
                }
            )
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(reachedPublication.withLock { $0 })
        #expect(try source.archiveBytes() == previous)
        try source.expectNoExportStaging()
    }

    @Test(arguments: [false, true])
    func concurrentPurgeWaitsForSnapshotAndCannotRemoveArchivedPayloads(pool: Bool) async throws {
        let source = try ArchiveLifecycleHarness(pool: pool)
        let destination = try ArchiveLifecycleHarness()
        defer { source.remove(); destination.remove() }
        let first = try await source.image(0x71)
        let second = try await source.image(0x72)
        let third = try await source.image(0x73)
        let fixtures = [first, second, third]
        let gate = ArchiveLifecycleGate()
        try await source.pauseSnapshot(at: gate)
        let exporting = Task { try await source.store.export(to: source.archive) }
        defer { exporting.cancel(); gate.release() }
        try await gate.waitUntilPaused()
        let started = AsyncStream<Void>.makeStream()
        let purgeFinished = Mutex(false)
        let purging = Task {
            started.continuation.yield(())
            try await source.store.purge(keepingLatest: 0)
            purgeFinished.withLock { $0 = true }
        }
        defer { purging.cancel() }
        for await _ in started.stream {
            break
        }
        #expect(!purgeFinished.withLock { $0 })
        gate.release()
        let summary = try await exporting.value
        try await purging.value
        #expect(!gate.timedOut)
        #expect(summary.itemCount == fixtures.count)
        #expect(summary.blobCount == fixtures.count)
        #expect(summary.blobsMissing == 0)
        #expect(try await source.store.recent().isEmpty)
        for fixture in fixtures {
            #expect(!source.blobs.exists(hash: fixture.hash))
        }
        let imported = try await destination.store.import(from: source.archive)
        #expect(imported.imported == fixtures.count)
        #expect(imported.missingBlobs == 0)
        for fixture in fixtures {
            let restored = try #require(await destination.store.materialize(itemIDs: [fixture.item.id]).first)
            #expect(restored.representations.map(\.payload) == [fixture.bytes])
        }
        try source.expectNoExportStaging()
    }

    @Test(arguments: [false, true])
    func concurrentPurgeBeforeSnapshotExportsExactlyPinnedSurvivors(pool: Bool) async throws {
        let source = try ArchiveLifecycleHarness(pool: pool)
        let destination = try ArchiveLifecycleHarness()
        defer { source.remove(); destination.remove() }
        let kept = try await source.image(0x81)
        try await source.store.setPinned(id: kept.item.id, true)
        let removed = try await source.image(0x82)
        let gate = ArchiveLifecycleGate()
        try await source.pauseStatement("SELECT id FROM item WHERE deletedAt IS NOT NULL", at: gate)
        let purging = Task { try await source.store.purge(keepingLatest: 0) }
        defer { purging.cancel(); gate.release() }
        try await gate.waitUntilPaused()
        let started = AsyncStream<Void>.makeStream()
        let exportFinished = Mutex(false)
        let exporting = Task {
            started.continuation.yield(())
            let result = try await source.store.export(to: source.archive)
            exportFinished.withLock { $0 = true }
            return result
        }
        defer { exporting.cancel() }
        for await _ in started.stream {
            break
        }
        #expect(!exportFinished.withLock { $0 })
        gate.release()
        try await purging.value
        let summary = try await exporting.value
        #expect(!gate.timedOut)
        #expect(summary.itemCount == 1)
        #expect(summary.blobCount == 1)
        #expect(summary.blobsMissing == 0)
        #expect(!source.blobs.exists(hash: removed.hash))
        let imported = try await destination.store.import(from: source.archive)
        #expect(imported.imported == 1)
        #expect(imported.missingBlobs == 0)
        #expect(try await destination.store.recent().map(\.id) == [kept.item.id])
        let restored = try #require(await destination.store.materialize(itemIDs: [kept.item.id]).first)
        #expect(restored.item.isPinned)
        #expect(restored.representations.map(\.payload) == [kept.bytes])
        try source.expectNoExportStaging()
    }
}
