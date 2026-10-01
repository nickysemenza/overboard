import Foundation
import GRDB
@testable import OverboardCore
import Testing

struct Wave3FileSearchTests {
    private func file(_ name: String, directory: String = "/fixture") -> IndexedFile {
        IndexedFile(path: directory + "/" + name, name: name, root: "/fixture", generation: "test")
    }

    @Test func transposedFiveLetterQueryRecallsNotes() async throws {
        let index = try FileNameIndex()
        try await index.upsert([self.file("notes.md"), self.file("unrelated.md")])
        let results = try await index.search("noets")
        #expect(results.first?.id == "file:/fixture/notes.md")
    }

    @Test func denseCandidatesValidateEveryTermBeforeSaturating() async throws {
        let index = try FileNameIndex()
        var files = (0 ..< 2000).map { self.file("notes-\($0).md", directory: "/fixture/common") }
        files.append(self.file("notes-special.md", directory: "/fixture/ab"))
        files.append(self.file("notes-fuzzy.md", directory: "/fixture/ab/budget"))
        try await index.upsert(files)
        #expect(try await index.search("notes ab").count == 2)
        #expect(try await index.search("notes ab budegt").first?.id == "file:/fixture/ab/budget/notes-fuzzy.md")
    }

    @Test func densePathMatchesCannotEvictExactFilename() async throws {
        let index = try FileNameIndex()
        var files = (0 ..< 2200).map { self.file("notes-\($0).md", directory: "/fixture/notes") }
        files.append(self.file("notes.md", directory: "/fixture/deep/other/location"))
        try await index.upsert(files)
        #expect(try await index.search("notes", limit: 1).first?.id == "file:/fixture/deep/other/location/notes.md")
    }

    @Test func learnedSixtyFirstCandidateRanksBeforeTopK() async throws {
        let index = try FileNameIndex()
        let files = (0 ..< 100).map { self.file(String(format: "report-%03d.txt", $0)) }
        try await index.upsert(files)
        let learned = files[60].result.id
        #expect(try await !((index.search("report")).contains { $0.id == learned }))
        let context = LauncherSearchContext(usage: [learned: 4])
        #expect(try await index.search("report", limit: 60, context: context).first?.id == learned)
        #expect(try await index.search("unrelated", context: context).isEmpty)
    }

    @Test func diskUsesWALAndRemovesAllOwnersOfDeletedSubtree() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("files.sqlite")
        let index = try FileNameIndex(url: url)
        let audit = try DatabaseQueue(path: url.path)
        #expect(try await audit.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") } == "wal")
        try await index.upsert([
            self.file("outer.txt", directory: "/fixture/nested"),
            IndexedFile(
                path: "/fixture/nested/inner.txt",
                name: "inner.txt",
                root: "/fixture/nested",
                generation: "test"
            ),
            self.file("keep.txt", directory: "/fixture/nested-other"),
        ])
        try await index.remove(under: "/fixture/nested")
        #expect(try await index.count() == 1)
        #expect(try await index.search("keep").count == 1)
    }
}
