import Foundation
import OverboardCore
@testable import OverboardMac
import Testing

struct FileMetadataScannerTests {
    @Test func indexesMetadataAndReconcilesRenameAndDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("node_modules"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("hello.txt")
        try Data("not needed for indexing".utf8).write(to: original)
        try Data().write(to: root.appendingPathComponent("node_modules/junk.txt"))
        let index = try FileNameIndex()
        #expect(try await FileMetadataScanner.scan(
            root: root,
            exclusions: ["node_modules"],
            generation: "one",
            index: index
        ).isEmpty)
        #expect(try await index.search("hello").count == 1)
        #expect(try await index.search("junk").isEmpty)
        let renamed = root.appendingPathComponent("goodbye.txt")
        try FileManager.default.moveItem(at: original, to: renamed)
        _ = try await FileMetadataScanner.scan(
            root: root,
            exclusions: ["node_modules"],
            generation: "two",
            index: index
        )
        #expect(try await index.search("hello").isEmpty)
        #expect(try await index.search("goodbye").count == 1)
        try FileManager.default.removeItem(at: renamed)
        _ = try await FileMetadataScanner.scan(
            root: root,
            exclusions: ["node_modules"],
            generation: "three",
            index: index
        )
        #expect(try await index.search("goodbye").isEmpty)
    }

    @Test func incrementalScanKeepsItsDirectoryAndReconcilesUnicodePaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("Cafe\u{301} 👩‍💻")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = folder.appendingPathComponent("old.txt")
        try Data().write(to: file)
        let index = try FileNameIndex()
        _ = try await FileMetadataScanner.scan(root: root, exclusions: [], generation: "one", index: index)
        try FileManager.default.removeItem(at: file)
        let issues = try await FileMetadataScanner.scan(
            root: root,
            exclusions: [],
            generation: "two",
            index: index,
            under: folder
        )
        #expect(issues.isEmpty)
        #expect(try await index.search("old.txt").isEmpty)
        let rows = try await index.search("cafe")
        #expect(rows.count == 1)
        guard case let .file(_, _, info) = rows.first else { Issue.record("Folder disappeared"); return }
        #expect(info.isDirectory)
    }

    @Test func excludesInternalsButAllowsExplicitCloudRoots() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        let item = cloud.appendingPathComponent("Documents/budget.xlsx")
        #expect(!FileMetadataScanner.shouldInclude(item, root: home, exclusions: []))
        #expect(FileMetadataScanner.shouldInclude(item, root: cloud, exclusions: []))
        #expect(!FileMetadataScanner.shouldInclude(
            home.appendingPathComponent("dev/.git/config"),
            root: home,
            exclusions: []
        ))
        #expect(!FileMetadataScanner.shouldInclude(
            home.appendingPathComponent("private/report.pdf"),
            root: home,
            exclusions: [home.appendingPathComponent("private").path]
        ))
    }

    @Test func inclusionSurvivesDeletionUnderCanonicalTemporaryRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalRoot = FileMetadataScanner.canonicalURL(root)
        let file = canonicalRoot.appendingPathComponent("deleted.txt")
        try Data().write(to: file)
        #expect(FileMetadataScanner.shouldInclude(file, root: canonicalRoot, exclusions: []))
        try FileManager.default.removeItem(at: file)
        #expect(FileMetadataScanner.shouldInclude(file, root: canonicalRoot, exclusions: []))
    }

    @Test func deniedLocationPreservesKnownMetadataAndReportsAccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("restricted.txt")
        try Data("fixture".utf8).write(to: file)
        let index = try FileNameIndex()
        _ = try await FileMetadataScanner.scan(root: root, exclusions: [], generation: "one", index: index)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let issues = try await FileMetadataScanner.scan(root: root, exclusions: [], generation: "two", index: index)
        #expect(!issues.isEmpty)
        #expect(try await index.search("restricted.txt").count == 1)
    }

    @Test func missingLocationPreservesKnownFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let index = try FileNameIndex()
        try await index.upsert([
            IndexedFile(
                path: root.appendingPathComponent("known.pdf").path,
                name: "known.pdf",
                root: root.path,
                generation: "old"
            ),
        ])
        let issues = try await FileMetadataScanner.scan(root: root, exclusions: [], generation: "new", index: index)
        #expect(!issues.isEmpty)
        #expect(try await index.search("known").count == 1)
    }
}
