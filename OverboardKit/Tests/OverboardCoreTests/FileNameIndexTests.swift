import Foundation
import GRDB
@testable import OverboardCore
import Testing

struct FileNameIndexTests {
    private func entry(_ path: String, generation: String = "one",
                       availability: FileSearchInfo.Availability = .local) -> IndexedFile
    {
        IndexedFile(
            path: path,
            name: (path as NSString).lastPathComponent,
            root: "/fixture",
            generation: generation,
            availability: availability
        )
    }

    @Test func searchesNamesPathsTyposAndCloudMetadata() async throws {
        let index = try FileNameIndex()
        try await index.upsert([
            self.entry("/fixture/iCloud Drive/Wedding/2026 budget.xlsx", availability: .cloud),
            self.entry("/fixture/Work/budget.xlsx"), self.entry("/fixture/hello.txt"),
            self.entry("/fixture/notes.md"), self.entry("/fixture/UX/AB.pdf"), self.entry("/fixture/Café résumé.pdf"),
        ])
        let matches = try await index.search("wedding budget")
        #expect(matches.count == 1)
        guard case let .file(_, _, info) = matches.first else { Issue.record("Missing cloud file"); return }
        #expect(info.availability == .cloud)
        #expect(try await index.search("budegt").count == 2)
        #expect(try await index.search("nots").count == 1)
        #expect(try await index.search("cafe resume").count == 1)
        #expect(try await index.search("unrelated").isEmpty)
        #expect(try await index.search("ux ab").count == 1)
    }

    @Test func scanReconciliationPreservesOtherRootsAndUnvisitedSubtrees() async throws {
        let index = try FileNameIndex()
        try await index.upsert([self.entry("/fixture/a/old.txt"), self.entry("/fixture/b/keep.txt")])
        try await index.beginScan("two")
        try await index.upsert([self.entry("/fixture/a/new.txt", generation: "two")], seenIn: "two")
        try await index.finishScan(root: "/fixture", generation: "two", under: "/fixture/a")
        #expect(try await index.search("old").isEmpty)
        #expect(try await index.search("keep").count == 1)
        #expect(try await index.search("new").count == 1)
    }

    @Test func unchangedRescanPerformsNoPersistentUpdatesAndStillReconciles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("files.sqlite")
        let index = try FileNameIndex(url: url)
        let audit = try DatabaseQueue(path: url.path)
        try await audit.write { db in
            try db.execute(sql: "CREATE TABLE file_update_audit (updates INTEGER NOT NULL)")
            try db.execute(sql: "INSERT INTO file_update_audit VALUES (0)")
            try db.execute(sql: """
            CREATE TRIGGER audit_file_update AFTER UPDATE ON file_entry BEGIN
                UPDATE file_update_audit SET updates = updates + 1;
            END;
            """)
        }

        try await index.upsert([self.entry("/fixture/report.pdf")])
        try await index.beginScan("two")
        try await index.upsert([self.entry("/fixture/report.pdf", generation: "two")], seenIn: "two")
        try await index.finishScan(root: "/fixture", generation: "two")
        let unchangedUpdates = try await audit.read { db in
            try Int.fetchOne(db, sql: "SELECT updates FROM file_update_audit")
        }
        #expect(unchangedUpdates == 0)

        try await index.beginScan("three")
        try await index.upsert([
            self.entry("/fixture/report.pdf", generation: "three", availability: .cloud),
        ], seenIn: "three")
        try await index.finishScan(root: "/fixture", generation: "three")
        let changedUpdates = try await audit.read { db in
            try Int.fetchOne(db, sql: "SELECT updates FROM file_update_audit")
        }
        #expect(changedUpdates == 1)
        guard case let .file(_, _, info) = try await index.search("report").first else {
            Issue.record("Updated file disappeared")
            return
        }
        #expect(info.availability == .cloud)

        try await index.beginScan("four")
        try await index.finishScan(root: "/fixture", generation: "four")
        #expect(try await index.count() == 0)
    }

    @Test func reopenedIndexRetainsMetadataAndCanRebuild() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("files.sqlite")
        let first = try FileNameIndex(url: url)
        try await first.upsert([self.entry("/fixture/report.pdf")])
        let second = try FileNameIndex(url: url)
        #expect(try await second.search("report").count == 1)
        try await second.reset()
        #expect(try await second.count() == 0)
    }
}
