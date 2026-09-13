import Foundation
import OverboardCore
@testable import OverboardMac
import Testing

@MainActor
struct FileIndexEventsTests {
    /// Waits for index passes until `condition` holds, parking on the service's
    /// own reconcile signal rather than polling on a sleep. FSEvents can split
    /// one change across several deliveries, so this takes however many passes
    /// it takes rather than assuming the first one settles it; the suite's
    /// `.timeLimit` is what stops a dropped delivery from hanging forever.
    private func settles(
        _ service: FileIndexService, until condition: () async throws -> Bool
    ) async throws {
        while try await !condition() {
            await service.nextReconcile()
        }
    }

    /// The only real clock in this test: FSEvents delivery plus the refresh
    /// debounce is seconds of genuinely asynchronous OS work, so the limit is
    /// a failure deadline, not a wait.
    @Test(.timeLimit(.minutes(1)))
    func watchesCreationRenameAndDeletionWithoutManualRebuilds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try FileNameIndex()
        let service = FileIndexService(index: index, roots: [root], exclusions: [])
        service.start()
        // Parking before the first suspension point is what makes this
        // deterministic: `start()` only schedules the scan, so the signal
        // cannot land before this call registers for it.
        await service.nextReconcile()
        try #require(!service.isIndexing)

        let original = root.appendingPathComponent("created-fixture.txt")
        try Data("metadata only".utf8).write(to: original)
        try await self.settles(service) { try await index.search("created-fixture.txt").count == 1 }

        let renamed = root.appendingPathComponent("renamed-fixture.txt")
        try FileManager.default.moveItem(at: original, to: renamed)
        try await self.settles(service) {
            let old = try await index.search("created-fixture.txt")
            let new = try await index.search("renamed-fixture.txt")
            return old.isEmpty && new.count == 1
        }

        try FileManager.default.removeItem(at: renamed)
        try await self.settles(service) { try await index.search("renamed-fixture.txt").isEmpty }
    }
}
