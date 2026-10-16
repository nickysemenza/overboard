import CoreServices
import Foundation
import OverboardCore
@testable import OverboardMac
import Testing

@MainActor
struct FileIndexChangeTests {
    private func service(roots: [URL]) throws -> FileIndexService {
        let service = try FileIndexService(index: FileNameIndex(), roots: roots, exclusions: [])
        service.activeRoots = roots
        return service
    }

    @Test func eventsKeepOrdinaryDirectoriesShallowAndMovesRecursive() throws {
        let root = URL(fileURLWithPath: "/fixture", isDirectory: true)
        let service = try self.service(roots: [root])
        let modified = UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemModified)
        service.enqueueEvents(["/fixture/folder"], flags: [modified])
        #expect(service.consumeDirtyChanges().first?.scope == .children)
        let renamed = UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed)
        service.enqueueEvents(["/fixture/folder"], flags: [renamed])
        #expect(service.consumeDirtyChanges().first?.scope == .subtree)
        service.enqueueEvents(["/fixture/file.txt"], flags: [UInt32(kFSEventStreamEventFlagItemModified)])
        #expect(service.consumeDirtyChanges().first?.scope == .entry)
    }

    @Test func localRecoveryDoesNotRescanOtherRootsButDroppedEventsDo() throws {
        let roots = [
            URL(fileURLWithPath: "/fixture/local", isDirectory: true),
            URL(fileURLWithPath: "/fixture/cloud", isDirectory: true),
        ]
        let service = try self.service(roots: roots)
        service.enqueueEvents(["/fixture/local/project"], flags: [UInt32(kFSEventStreamEventFlagMustScanSubDirs)])
        let local = service.consumeDirtyChanges()
        #expect(local.count == 1)
        #expect(local.first?.path.path == "/fixture/local/project")
        #expect(local.first?.scope == .subtree)
        service.enqueueEvents(["/fixture/local/project"], flags: [UInt32(kFSEventStreamEventFlagUserDropped)])
        #expect(Set(service.consumeDirtyChanges().map(\.path.path)) == Set(roots.map(\.path)))
    }

    @Test func shallowScopeNeverSwallowsNestedChangesOrAnotherRoot() throws {
        let root = URL(fileURLWithPath: "/fixture", isDirectory: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        let service = try self.service(roots: [root, nested])
        service.enqueueChange(root.path, scope: .children)
        service.enqueueChange("/fixture/direct.txt")
        service.enqueueChange("/fixture/folder/deep.txt")
        service.enqueueChange("/fixture/nested/owned.txt")
        service.enqueueChange("/fixture/folder", scope: .subtree)
        let changes = service.consumeDirtyChanges()
        #expect(changes.count == 3)
        #expect(changes.contains { $0.path.path == "/fixture/folder" && $0.scope == .subtree })
        #expect(changes.contains { $0.path.path == "/fixture/nested/owned.txt" })
    }

    @Test func parentRecoveryIncludesSeparatelyOwnedNestedRoots() throws {
        let roots = [
            URL(fileURLWithPath: "/fixture", isDirectory: true),
            URL(fileURLWithPath: "/fixture/cloud", isDirectory: true),
            URL(fileURLWithPath: "/unrelated", isDirectory: true),
        ]
        let service = try self.service(roots: roots)
        service.enqueueEvents(["/fixture"], flags: [UInt32(kFSEventStreamEventFlagMustScanSubDirs)])
        let paths = Set(service.consumeDirtyChanges().map(\.path.path))
        #expect(paths == ["/fixture", "/fixture/cloud"])
    }

    @Test func gitignoreChangesRefreshNoiseClassificationUnderItsParent() throws {
        let service = try self.service(roots: [URL(fileURLWithPath: "/fixture", isDirectory: true)])
        service.enqueueEvents(["/fixture/project/.gitignore"], flags: [UInt32(kFSEventStreamEventFlagItemModified)])
        let changes = service.consumeDirtyChanges()
        #expect(changes.count == 1)
        #expect(changes.first?.path.path == "/fixture/project")
        #expect(changes.first?.scope == .subtree)
    }

    @Test func overflowCoalescesSiblingsWithoutPromotingUnrelatedRoots() throws {
        let roots = [
            URL(fileURLWithPath: "/fixture/local", isDirectory: true),
            URL(fileURLWithPath: "/fixture/cloud", isDirectory: true),
        ]
        let service = try self.service(roots: roots)
        service.enqueueChange("/fixture/cloud/keep.txt")
        for offset in 0 ..< 1000 {
            service.enqueueChange("/fixture/local/project/file-\(offset).txt")
        }
        #expect(service.dirtyPaths.count <= 512)
        #expect(service.dirtyPaths.contains("/fixture/cloud/keep.txt"))
        #expect(service.dirtyScopes["/fixture/local/project"] == .children)
        #expect(!service.dirtyPaths.contains("/fixture/local"))
        #expect(!service.dirtyPaths.contains("/fixture/cloud"))
    }
}
