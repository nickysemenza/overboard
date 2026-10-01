import Foundation
import OverboardCore
@testable import OverboardMac
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct FileIndexLifecycleTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return FileMetadataScanner.canonicalURL(root)
    }

    private var rows: [LauncherResult] {
        [IndexedFile(path: "/fixture/notes.txt", name: "notes.txt", root: "/fixture", generation: "test").result]
    }

    @Test func stoppedServiceRejectsSuccessfulSuspendedQueryAndNewQueries() async throws {
        let gate = LifecycleReadGate<[LauncherResult]>()
        let service = try FileIndexService(
            index: FileNameIndex(), roots: [], operations: FileIndexOperations(search: { _, _, _ in await gate.read() })
        )
        let query = Task { await service.results(for: "notes") }
        await gate.waitForReads(1)
        service.stop()
        await gate.release(returning: self.rows)
        #expect(await query.value.isEmpty)
        #expect(await service.results(for: "notes").isEmpty)
        #expect(await gate.count == 1)
    }

    @Test func rebuildRejectsOldQueryButAllowsCurrentGeneration() async throws {
        let root = try self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = LifecycleReadGate<[LauncherResult]>()
        let service = try FileIndexService(
            index: FileNameIndex(), roots: [root],
            operations: FileIndexOperations(search: { _, _, _ in await gate.read() }, scan: { _ in [] })
        )
        defer { service.stop() }
        let oldQuery = Task { await service.results(for: "notes") }
        await gate.waitForReads(1)
        service.rebuild(clear: false)
        await service.scanTask?.value
        await gate.release(returning: self.rows)
        #expect(await oldQuery.value.isEmpty)
        let newQuery = Task { await service.results(for: "notes") }
        await gate.waitForReads(2)
        await gate.release(2, returning: self.rows)
        #expect(await newQuery.value == self.rows)
    }

    @Test func cancelledQueryCannotReturnSuccessfulRows() async throws {
        let gate = LifecycleReadGate<[LauncherResult]>()
        let service = try FileIndexService(
            index: FileNameIndex(), roots: [], operations: FileIndexOperations(search: { _, _, _ in await gate.read() })
        )
        defer { service.stop() }
        let query = Task { await service.results(for: "notes") }
        await gate.waitForReads(1)
        query.cancel()
        await gate.release(returning: self.rows)
        #expect(await query.value.isEmpty)
    }

    @Test func fullScanRestartWaitsForRetirementAndDoesNotPublishOldIssues() async throws {
        let root = try self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = LifecycleReadGate<[String]>()
        let service = try FileIndexService(
            index: FileNameIndex(), roots: [root], operations: FileIndexOperations(scan: { _ in await gate.read() })
        )
        var publications = 0
        service.onChange = { publications += 1 }
        service.start()
        defer { service.stop() }
        await gate.waitForReads(1)
        let oldScan = service.scanTask
        service.stop()
        let countAtStop = publications
        service.start()
        #expect(await gate.count == 1)
        await gate.release(returning: ["Obsolete issue"])
        await oldScan?.value
        await gate.waitForReads(2)
        #expect(service.issues.isEmpty)
        #expect(publications == countAtStop)
        let currentScan = service.scanTask
        await gate.release(2, returning: [])
        await currentScan?.value
        #expect(service.issues.isEmpty)
        #expect(!service.isIndexing)
        #expect(publications > countAtStop)
    }

    @Test func restartWaitsForIncrementalRefreshToRetire() async throws {
        let root = try self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = LifecycleReadGate<[String]>()
        let scans = LifecycleScanCounter()
        let service = try FileIndexService(
            index: FileNameIndex(), roots: [root], operations: FileIndexOperations(
                scan: { _ in await scans.scan() }, refresh: { _ in await gate.read() }
            )
        )
        service.start()
        defer { service.stop() }
        await service.scanTask?.value
        service.enqueueChange(root.appendingPathComponent("changed.txt").path)
        service.scheduleRefresh(delay: .zero)
        await gate.waitForReads(1)
        let oldRefresh = service.refreshTask
        service.stop()
        service.start()
        await Task.yield()
        #expect(await scans.count == 1)
        await gate.release(returning: ["Obsolete refresh issue"])
        await oldRefresh?.value
        await service.scanTask?.value
        #expect(await scans.count == 2)
        #expect(service.issues.isEmpty)
        #expect(!service.isIndexing)
    }
}

private actor LifecycleScanCounter {
    private(set) var count = 0

    func scan() -> [String] {
        self.count += 1
        return []
    }
}
