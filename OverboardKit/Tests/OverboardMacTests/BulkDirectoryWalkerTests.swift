import Foundation
@testable import OverboardMac
import Testing

struct BulkDirectoryWalkerTests {
    @Test func classifiesPackagesByExtensionAndBundleBit() {
        let classifier = PackageClassifier()
        for name in ["Tool.app", "Plugin.bundle", "Note.rtfd", "UPPER.APP"] {
            #expect(classifier.isPackage(name: name, finderFlags: 0), "\(name)")
        }
        #expect(!classifier.isPackage(name: "foo.v2", finderFlags: 0))
        #expect(!classifier.isPackage(name: "plain", finderFlags: 0))
        #expect(!classifier.isPackage(name: ".app", finderFlags: 0))
        #expect(classifier.isPackage(name: "foo.v2", finderFlags: BulkDirectoryWalker.hasBundleFinderFlag))
    }

    @Test func listsMetadataWithoutFollowingSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dir.v2"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent("file.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"),
                                                   withDestinationURL: root.appendingPathComponent("dir.v2"))
        let listing = BulkDirectoryWalker().list(path: root.path)
        #expect(listing.error == nil)
        #expect(listing.entries.count == 3)
        let byName = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.name, $0) })
        #expect(byName["dir.v2"]?.isDirectory == true)
        #expect(byName["file.txt"]?.kind == .regular)
        #expect(byName["link"]?.isSymbolicLink == true)
        #expect(byName["file.txt"]?.availability == .local)
        #expect(abs(byName["file.txt"]?.modifiedAt.timeIntervalSinceNow ?? 999) < 60)
        let single = try BulkDirectoryWalker.stat(path: root.appendingPathComponent("file.txt").path)
        #expect(single.name == "file.txt")
    }

    @Test func reportsMissingDirectoryAsError() {
        let listing = BulkDirectoryWalker().list(path: "/nonexistent-\(UUID().uuidString)")
        #expect(listing.error?.code == ENOENT)
    }
}
