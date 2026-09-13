import Foundation
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
        try await index.upsert([self.entry("/fixture/a/new.txt", generation: "two")])
        try await index.finishScan(root: "/fixture", generation: "two", under: "/fixture/a")
        #expect(try await index.search("old").isEmpty)
        #expect(try await index.search("keep").count == 1)
        #expect(try await index.search("new").count == 1)
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
