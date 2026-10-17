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
        // The first launch saved scan progress, so the restart resumes from it
        // instead of scanning again.
        #expect(await scans.count == 1)
        #expect(service.issues.isEmpty)
        #expect(!service.isIndexing)
    }

    // MARK: Resuming from saved scan progress

    private func scanning(_ index: FileNameIndex, roots: [URL], exclusions: [String] = [],
                          scans: LifecycleScanCounter) -> FileIndexService
    {
        FileIndexService(
            index: index, roots: roots, exclusions: exclusions,
            operations: FileIndexOperations(scan: { _ in await scans.scan() })
        )
    }

    @Test func relaunchWithSavedProgressSkipsTheFullScan() async throws {
        let root = try self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try FileNameIndex()
        let scans = LifecycleScanCounter()
        let first = self.scanning(index, roots: [root], scans: scans)
        first.start()
        await first.scanTask?.value
        first.stop()
        #expect(await scans.count == 1)
        #expect(try await index.scanStates().map(\.root) == [root.path])

        let second = self.scanning(index, roots: [root], scans: scans)
        second.start()
        defer { second.stop() }
        await second.scanTask?.value
        #expect(await scans.count == 1)
        #expect(!second.isIndexing)
        #expect(second.status.contains("ready"))
    }

    @Test func changedRootsOrExclusionsInvalidateSavedProgress() async throws {
        let root = try self.root()
        let other = try self.root()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: other)
        }
        let index = try FileNameIndex()
        let scans = LifecycleScanCounter()
        let first = self.scanning(index, roots: [root], scans: scans)
        first.start()
        await first.scanTask?.value
        first.stop()

        let changedExclusions = self.scanning(index, roots: [root], exclusions: ["build"], scans: scans)
        changedExclusions.start()
        await changedExclusions.scanTask?.value
        changedExclusions.stop()
        #expect(await scans.count == 2)

        // Adding a root changes the configuration, so even the old root rescans.
        let changedRoots = self.scanning(index, roots: [root, other], exclusions: ["build"], scans: scans)
        changedRoots.start()
        await changedRoots.scanTask?.value
        changedRoots.stop()
        #expect(await scans.count == 4)
    }

    @Test func clearingRebuildAlwaysScansAndFailedScansLeaveNoProgress() async throws {
        let root = try self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try FileNameIndex()
        let scans = LifecycleScanCounter()
        let service = self.scanning(index, roots: [root], scans: scans)
        service.start()
        await service.scanTask?.value
        service.rebuild(clear: true)
        await service.scanTask?.value
        service.stop()
        #expect(await scans.count == 2)

        let failing = try FileIndexService(
            index: FileNameIndex(), roots: [root],
            operations: FileIndexOperations(scan: { _ in ["\(root.path): Couldn\u{2019}t read this location."] })
        )
        failing.start()
        await failing.scanTask?.value
        failing.stop()
        #expect(try await failing.index?.scanStates().isEmpty == true)
    }

    @Test func partiallyResumedLaunchOnlyScansRootsWithoutProgress() async throws {
        let root = try self.root()
        let other = try self.root()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: other)
        }
        let index = try FileNameIndex()
        let scans = LifecycleScanCounter()
        let first = self.scanning(index, roots: [root, other], scans: scans)
        first.start()
        await first.scanTask?.value
        first.stop()
        #expect(await scans.count == 2)
        try await index.clearScanState(root: other.path)

        let second = self.scanning(index, roots: [root, other], scans: scans)
        second.start()
        defer { second.stop() }
        await second.scanTask?.value
        #expect(await scans.count == 3)
    }

    @Test func resumePointsRequireMatchingDeviceConfigAgeAndAPastEventID() {
        let root = URL(fileURLWithPath: "/fixture/root", isDirectory: true)
        let now = Date()
        func state(device: String = "DEVICE", config: String = "cfg", event: UInt64 = 10, age: TimeInterval = 60)
            -> FileIndexScanState
        {
            FileIndexScanState(root: root.path, deviceUUID: device, eventID: event, configHash: config,
                               completedAt: now.addingTimeInterval(-age))
        }
        func points(_ saved: FileIndexScanState) -> [String: UInt64] {
            FileIndexService.resumePoints(
                roots: [root], states: [saved], configHash: "cfg", now: now, currentEventID: 100,
                deviceUUID: { _ in "DEVICE" }
            )
        }
        #expect(points(state()) == [root.path: 10])
        #expect(points(state(device: "OTHER")).isEmpty)
        #expect(points(state(config: "changed")).isEmpty)
        #expect(points(state(event: 101)).isEmpty)
        #expect(points(state(age: FileIndexService.maxResumeAge + 1)).isEmpty)
    }

    @Test func configHashIsStableAndOrderIndependent() {
        let (first, second) = (URL(fileURLWithPath: "/fixture/a"), URL(fileURLWithPath: "/fixture/b"))
        let hash = FileIndexService.configHash(roots: [first, second], exclusions: ["x", "y"])
        #expect(hash == FileIndexService.configHash(roots: [second, first], exclusions: [" y", "x", ""]))
        #expect(hash != FileIndexService.configHash(roots: [first], exclusions: ["x", "y"]))
        #expect(hash != FileIndexService.configHash(roots: [first, second], exclusions: ["x"]))
    }

    @Test func dirtyOwnersTrackQueuedPathsThroughCoalescingAndConsumption() throws {
        let root = URL(fileURLWithPath: "/fixture", isDirectory: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        let service = try FileIndexService(index: FileNameIndex(), roots: [root, nested], operations: .init())
        service.activeRoots = [root, nested]
        service.enqueueChange("/fixture/a/one.txt")
        service.enqueueChange("/fixture/a/two.txt")
        service.enqueueChange("/fixture/nested/three.txt")
        #expect(service.dirtyOwners["/fixture/a/one.txt"] == "/fixture")
        #expect(service.dirtyOwners["/fixture/nested/three.txt"] == "/fixture/nested")
        service.enqueueChange("/fixture/a", scope: .subtree)
        #expect(service.dirtyOwners.keys.sorted() == ["/fixture/a", "/fixture/nested/three.txt"])
        #expect(Set(service.dirtyOwners.keys) == service.dirtyPaths)
        _ = service.consumeDirtyChanges()
        #expect(service.dirtyOwners.isEmpty)
    }
}

private actor LifecycleScanCounter {
    private(set) var count = 0

    func scan() -> [String] {
        self.count += 1
        return []
    }
}
