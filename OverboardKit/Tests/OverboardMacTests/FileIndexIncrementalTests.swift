import Foundation
import OverboardCore
@testable import OverboardMac
import Testing

struct FileIndexIncrementalTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return FileMetadataScanner.canonicalURL(root)
    }

    @Test func directoryEntryRefreshDoesNotWalkItsChildren() async throws {
        let root = try self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try FileNameIndex()
        let child = root.appendingPathComponent("unrelated.txt")
        try Data().write(to: child)
        _ = try await FileMetadataScanner.refresh(root, roots: [root], exclusions: [], index: index, scope: .entry)
        #expect(try await index.search("unrelated").isEmpty)
    }

    @Test func symlinkRefreshDoesNotIndexItsTarget() async throws {
        let root = try self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.txt")
        let link = root.appendingPathComponent("link.txt")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let index = try FileNameIndex()
        _ = try await FileMetadataScanner.refresh(link, roots: [root], exclusions: [], index: index, scope: .entry)
        #expect(try await index.count() == 0)
    }

    @Test func directoryReplacedByFileLosesItsDescendants() async throws {
        let root = try self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("replaced", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("stale.txt"))
        let index = try FileNameIndex()
        _ = try await FileMetadataScanner.scan(root: root, exclusions: [], generation: "initial", index: index)
        try FileManager.default.removeItem(at: folder)
        try Data().write(to: root.appendingPathComponent("replaced"))
        _ = try await FileMetadataScanner.refresh(folder, roots: [root], exclusions: [], index: index, scope: .entry)
        #expect(try await index.search("stale").isEmpty)
        #expect(try await index.search("replaced").count == 1)
    }

    @Test func childrenRefreshPreservesUntouchedDescendantsAndDiscoversNewTrees() async throws {
        let root = try self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("untouched.txt")
        try Data().write(to: file)
        let oldDate = Date(timeIntervalSince1970: 1000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
        let index = try FileNameIndex()
        _ = try await FileMetadataScanner.scan(root: root, exclusions: [], generation: "initial", index: index)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        let incoming = root.appendingPathComponent("incoming/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try Data().write(to: incoming.appendingPathComponent("discovered.txt"))
        _ = try await FileMetadataScanner.refresh(root, roots: [root], exclusions: [], index: index, scope: .children)
        let result = try #require(try await index.search("untouched").first)
        guard case let .file(_, _, info) = result else { Issue.record("Expected a file"); return }
        #expect(info.modifiedAt == oldDate)
        #expect(try await index.search("discovered").count == 1)
    }

    @Test func childrenRefreshRemovesDeletedTreesAndReconcilesRenames() async throws {
        let root = try self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = root.appendingPathComponent("original/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data().write(to: tree.appendingPathComponent("nested.txt"))
        let index = try FileNameIndex()
        _ = try await FileMetadataScanner.scan(root: root, exclusions: [], generation: "initial", index: index)
        let moved = root.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent("original"), to: moved)
        _ = try await FileMetadataScanner.refresh(root, roots: [root], exclusions: [], index: index, scope: .children)
        #expect(try await index.search("original").isEmpty)
        #expect(try await index.search("nested").first?.id == "file:" + moved.appendingPathComponent("deep/nested.txt")
            .path)
        try FileManager.default.removeItem(at: moved)
        _ = try await FileMetadataScanner.refresh(root, roots: [root], exclusions: [], index: index, scope: .children)
        #expect(try await index.search("nested").isEmpty)
    }
}
