import CoreServices
import Foundation
import OverboardCore
@testable import OverboardMac
import Testing

struct FileIndexEventFilterTests {
    private let home = FileMetadataScanner.canonicalURL(FileManager.default.homeDirectoryForCurrentUser).path
    private let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)

    private func policy() -> FileIndexPathPolicy {
        FileIndexPathPolicy(
            roots: [
                URL(fileURLWithPath: self.home, isDirectory: true),
                URL(fileURLWithPath: self.home + "/Library/CloudStorage/Drive", isDirectory: true),
                URL(fileURLWithPath: "/fixture/external", isDirectory: true),
            ],
            exclusions: ["node_modules", self.home + "/Documents/Skipped"]
        )
    }

    private var samples: [String] {
        [
            "\(self.home)/Documents/report.pdf",
            "\(self.home)/Documents/Skipped/inner.txt",
            "\(self.home)/Documents/Skipped",
            "\(self.home)/Documents/Skipped2/inner.txt",
            "\(self.home)/Documents/proj/node_modules/pkg/index.js",
            "\(self.home)/Documents/proj/.git/HEAD",
            "\(self.home)/.claude/projects/x.jsonl",
            "\(self.home)/.zshrc",
            "\(self.home)/Library/Caches/com.example/blob",
            "\(self.home)/Library/Application Support/App/state.db",
            "\(self.home)/Library",
            "\(self.home)/LibraryNotes/a.txt",
            "\(self.home)/Library/CloudStorage/Drive/Docs/a.txt",
            "\(self.home)/Library/CloudStorage/Drive/.hidden/a.txt",
            "\(self.home)/Library/CloudStorage/Drive/node_modules/a.js",
            "\(self.home)/Library/CloudStorage/Other/a.txt",
            "/fixture/external/a.txt",
            "/fixture/external/dir/",
            "/fixture/elsewhere/a.txt",
            "/fixture/externalish/a.txt",
            "/fixture/external/.cache/a",
            "/",
        ]
    }

    @Test func prefilterAgreesWithPathPolicy() {
        let policy = self.policy()
        let filter = FileIndexEventFilter(policy: policy)
        for path in self.samples {
            let expected = policy.owner(of: URL(fileURLWithPath: path)) != nil
            #expect(filter.accepts(path, flags: self.modified) == expected, "\(path)")
        }
    }

    @Test func gitignoreChangesAreJudgedByTheirDirectory() {
        let policy = self.policy()
        let filter = FileIndexEventFilter(policy: policy)
        // The file is hidden, but its directory is indexed: must pass.
        #expect(filter.accepts("\(self.home)/Documents/proj/.gitignore", flags: self.modified))
        // Same file under a rejected directory must not reach the main actor.
        #expect(!filter.accepts("\(self.home)/Library/Caches/x/.gitignore", flags: self.modified))
        #expect(!filter.accepts("\(self.home)/.nx/.gitignore", flags: self.modified))
        #expect(!filter.accepts("\(self.home)/Documents/proj/node_modules/.gitignore", flags: self.modified))
    }

    @Test func recoveryOnAnAncestorOfANestedRootStillPasses() {
        let filter = FileIndexEventFilter(policy: self.policy())
        let recover = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        // `~/Library` is not indexed, but a subtree rescan of it must re-queue
        // the cloud root nested beneath it.
        #expect(filter.accepts("\(self.home)/Library", flags: recover))
        #expect(!filter.accepts("\(self.home)/Library", flags: self.modified))
        #expect(!filter.accepts("\(self.home)/Library/Caches", flags: recover))
    }

    @Test func decomposedUnicodePathsAreJudgedAfterNormalization() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("Caf\u{E9}", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let canonical = FileMetadataScanner.canonicalURL(root)
        let filter = FileIndexEventFilter(policy: FileIndexPathPolicy(roots: [canonical], exclusions: []))
        let decomposed = canonical.path.decomposedStringWithCanonicalMapping + "/a.txt"
        #expect(filter.accepts(decomposed, flags: self.modified))
    }

    @Test func batchesDropRejectedEventsButKeepTheEventIDAndLostSignal() {
        let filter = FileIndexEventFilter(policy: self.policy())
        let batch = filter.batch(
            paths: ["\(self.home)/Library/Caches/a", "\(self.home)/Documents/a.txt"],
            flags: [self.modified, self.modified], lastEventID: 42
        )
        #expect(batch.paths == ["\(self.home)/Documents/a.txt"])
        #expect(batch.lastEventID == 42)
        #expect(!batch.lost)
        let lost = filter.batch(
            paths: ["\(self.home)/Documents/a.txt"],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)], lastEventID: 43
        )
        #expect(lost.lost)
        let done = filter.batch(paths: [""], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)],
                                lastEventID: 44)
        #expect(done.historyDone)
        #expect(done.paths.isEmpty)
    }

    @Test func libraryIsExcludedFromTheHomeStreamAndCloudRootsGetTheirOwn() {
        let cloud = "\(self.home)/Library/CloudStorage/Drive"
        let plans = FileIndexService.streamPlans(
            roots: [self.home, cloud, "/fixture/external"], home: self.home,
            excluded: ["\(self.home)/Documents/Skipped", "/elsewhere/unrelated"]
        )
        #expect(plans == [
            .init(paths: [self.home, "/fixture/external"],
                  exclusions: ["\(self.home)/Library", "\(self.home)/Documents/Skipped"]),
            .init(paths: [cloud], exclusions: []),
        ])
    }

    @Test func exclusionsNeverSwallowARootAndAreCappedAtEight() {
        let plans = FileIndexService.streamPlans(
            roots: ["/fixture/a"], home: self.home,
            excluded: ["/fixture/a"] + (0 ..< 12).map { "/fixture/a/skip\($0)" }
        )
        #expect(plans.count == 1)
        #expect(plans[0].exclusions.count == 8)
        #expect(!plans[0].exclusions.contains("/fixture/a"))
    }
}
