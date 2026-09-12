import Foundation
import OverboardCore
@testable import OverboardMac
import Testing

@MainActor
struct FileIndexEventsTests {
    private func eventually(_ condition: () async throws -> Bool) async throws -> Bool {
        for _ in 0 ..< 160 {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test func watchesCreationRenameAndDeletionWithoutManualRebuilds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try FileNameIndex()
        let service = FileIndexService(index: index, roots: [root], exclusions: [])
        service.start()
        try #require(await self.eventually { !service.isIndexing })
        let original = root.appendingPathComponent("created-fixture.txt")
        try Data("metadata only".utf8).write(to: original)
        try #require(await self.eventually { try await index.search("created-fixture.txt").count == 1 })
        let renamed = root.appendingPathComponent("renamed-fixture.txt")
        try FileManager.default.moveItem(at: original, to: renamed)
        try #require(await self.eventually {
            let old = try await index.search("created-fixture.txt")
            let new = try await index.search("renamed-fixture.txt")
            return old.isEmpty && new.count == 1
        })
        try FileManager.default.removeItem(at: renamed)
        #expect(try await self.eventually { try await index.search("renamed-fixture.txt").isEmpty })
    }
}
