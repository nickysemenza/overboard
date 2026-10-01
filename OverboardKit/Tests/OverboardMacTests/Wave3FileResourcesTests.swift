import Foundation
import OverboardCore
@testable import OverboardMac
import Testing

@MainActor
struct Wave3FileResourcesTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return FileMetadataScanner.canonicalURL(root)
    }

    @Test func overlappingRootsRemainDeepestOwnedAfterParentAndDeletion() async throws {
        let root = try self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("notes.txt")
        try Data("test".utf8).write(to: file)
        let index = try FileNameIndex()
        let roots = [root, nested]
        _ = try await FileMetadataScanner.scan(
            root: nested,
            exclusions: [],
            generation: "child",
            index: index,
            roots: roots
        )
        _ = try await FileMetadataScanner.scan(
            root: root,
            exclusions: [],
            generation: "parent",
            index: index,
            roots: roots
        )
        try await index.retainRoots([nested.path])
        #expect(try await index.search("notes").count == 1)
        try FileManager.default.removeItem(at: nested)
        _ = try await FileMetadataScanner.refresh(nested, roots: roots, exclusions: [], index: index)
        #expect(try await index.search("notes").isEmpty)
    }

    @Test func packageAndExclusionRulesApplyToIncrementalScopes() async throws {
        let root = try self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Example.app", isDirectory: true)
        let content = package.appendingPathComponent("Contents", isDirectory: true)
        let excluded = root.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        let secret = content.appendingPathComponent("secret.txt")
        try Data().write(to: secret)
        try Data().write(to: excluded.appendingPathComponent("excluded.txt"))
        let index = try FileNameIndex()
        _ = try await FileMetadataScanner.scan(root: root, exclusions: ["build"], generation: "initial", index: index)
        _ = try await FileMetadataScanner.refresh(content, roots: [root], exclusions: ["build"], index: index)
        _ = try await FileMetadataScanner.refresh(excluded, roots: [root], exclusions: ["build"], index: index)
        _ = try await FileMetadataScanner.refresh(package, roots: [root], exclusions: ["build"], index: index)
        #expect(try await index.search("secret").isEmpty)
        #expect(try await index.search("excluded").isEmpty)
        #expect(try await index.search("Example").count == 1)
    }

    @Test func perFileChangesStayBoundedAndPreserveOldestWork() throws {
        let root = try self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try FileIndexService(index: FileNameIndex(), roots: [root], exclusions: [])
        service.activeRoots = [root]
        let first = root.appendingPathComponent("z-first.txt").path
        service.enqueueChange(first)
        for offset in 0 ..< 100 {
            service.enqueueChange(root.appendingPathComponent("a-\(offset).txt").path)
        }
        service.enqueueChange(first)
        let batch = service.consumeDirtyDirectories()
        #expect(batch.count == 32)
        #expect(batch.first?.path == first)
        #expect(!batch.contains(root))
        for offset in 0 ..< 1000 {
            service.enqueueChange(root.appendingPathComponent("extra-\(offset).txt").path)
        }
        #expect(service.dirtyPaths.count <= 512)
        #expect(service.dirtyPaths.contains(root.path))
        service.stop()
        service.enqueueChange(first)
        #expect(service.dirtyPaths.isEmpty)
    }

    @Test func concurrentAppRequestsUseOneScanAndLearnBeforeLimiting() async {
        let counter = Wave3AppScanCounter()
        let index = AppIndex(scanner: {
            await counter.scan()
        })
        async let first = index.entries()
        async let second = index.entries()
        let entries = await (first, second)
        #expect(entries.0 == entries.1)
        #expect(await counter.count == 1)
        let provider = AppSearchProvider(index: index, limit: 5)
        let learned = "app:/Applications/Notes 60.app"
        let results = await provider.results(for: "notes", context: LauncherSearchContext(usage: [learned: 3]))
        #expect(results.first?.id == learned)
        #expect(results.count == 5)
    }
}

private actor Wave3AppScanCounter {
    var count = 0

    func scan() async -> [AppIndex.Entry] {
        self.count += 1
        await Task.yield()
        return (0 ..< 80).map { AppIndex.Entry(
            name: "Notes \($0)",
            url: URL(fileURLWithPath: "/Applications/Notes \($0).app")
        ) }
    }
}
