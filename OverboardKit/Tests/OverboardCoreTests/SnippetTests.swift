import Foundation
@testable import OverboardCore
import Testing

struct SnippetTemplateTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_750_000_000)

    @Test func expandsDateAndTime() {
        let body = "Sent on {date} at {time}"
        let result = SnippetTemplate.expand(body, now: self.fixedDate)
        #expect(!result.contains("{date}"))
        #expect(!result.contains("{time}"))
        #expect(result.hasPrefix("Sent on "))
    }

    @Test func expandsClipboard() {
        let result = SnippetTemplate.expand("Re: {clipboard}", clipboard: "the meeting")
        #expect(result == "Re: the meeting")
    }

    @Test func missingClipboardBecomesEmpty() {
        let result = SnippetTemplate.expand("Re: {clipboard}", clipboard: nil)
        #expect(result == "Re: ")
    }

    @Test func eachUUIDIsFresh() {
        var counter = 0
        let result = SnippetTemplate.expand("{uuid} {uuid}") {
            counter += 1
            return "id-\(counter)"
        }
        #expect(result == "id-1 id-2")
    }

    @Test func plainBodyUntouched() {
        #expect(SnippetTemplate.expand("no placeholders here") == "no placeholders here")
    }
}

struct SnippetStoreTests {
    private func makeStore() throws -> ClipStore {
        let queue = try OverboardDatabase.openInMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-snip-\(UUID().uuidString)", isDirectory: true)
        return try ClipStore(dbWriter: queue, blobs: BlobStore(directory: dir))
    }

    @Test func savesListsAndDeletes() async throws {
        let store = try makeStore()
        let snippet = Snippet(title: "Greeting", body: "Hello {clipboard}!")
        try await store.saveSnippet(snippet)
        try await store.saveSnippet(Snippet(title: "Address", body: "1 Infinite Loop"))

        let all = try await store.snippets()
        #expect(all.count == 2)
        #expect(all.first?.title == "Address") // sorted by title

        try await store.deleteSnippet(id: snippet.id)
        #expect(try await store.snippets().count == 1)
    }

    @Test func updatesInPlace() async throws {
        let store = try makeStore()
        var snippet = Snippet(title: "Sig", body: "v1")
        try await store.saveSnippet(snippet)
        snippet.body = "v2"
        try await store.saveSnippet(snippet)

        let all = try await store.snippets()
        #expect(all.count == 1)
        #expect(all.first?.body == "v2")
    }

    @Test func searchMatchesTitleAndBody() async throws {
        let store = try makeStore()
        try await store.saveSnippet(Snippet(title: "Standup", body: "Yesterday / Today / Blockers"))
        try await store.saveSnippet(Snippet(title: "Email sig", body: "Best, Nicky"))

        #expect(try await store.searchSnippets("standup").count == 1)
        #expect(try await store.searchSnippets("blockers").count == 1)
        #expect(try await store.searchSnippets("nothing").isEmpty)
        #expect(try await store.searchSnippets("").count == 2)
    }
}
