import Foundation
@testable import OverboardCore
import Testing

struct SnippetRevisionTests {
    private func makeStore() throws -> ClipStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("snippet-revision-\(UUID().uuidString)")
        return try ClipStore(dbWriter: OverboardDatabase.openInMemory(), blobs: BlobStore(directory: directory))
    }

    @Test func staleRevisionCannotOverwriteConcurrentEdit() async throws {
        let store = try self.makeStore()
        let first = try await store.saveSnippet(Snippet(title: "Greeting", body: "first"))
        var edited = first
        edited.body = "newer"
        let latest = try await store.saveSnippet(edited, expectedRevision: first.lamport)
        #expect(latest.lamport == first.lamport + 1)
        do {
            try await store.saveSnippet(first, expectedRevision: first.lamport)
            Issue.record("Stale save succeeded")
        } catch let error as SnippetSaveError {
            #expect(error == .revisionConflict(id: first.id, expected: first.lamport, actual: latest.lamport))
        }
        #expect(try await store.snippets().first?.body == "newer")
    }

    @Test func deletedSnippetCannotBeResurrectedByAnOpenEditor() async throws {
        let store = try self.makeStore()
        let first = try await store.saveSnippet(Snippet(title: "Greeting", body: "first"))
        try await store.deleteSnippet(id: first.id)
        await #expect(throws: SnippetSaveError.self) {
            try await store.saveSnippet(first, expectedRevision: first.lamport)
        }
        #expect(try await store.snippets().isEmpty)
    }

    @Test func legacySavesStillAdvanceTheStoredRevision() async throws {
        let store = try self.makeStore()
        let draft = Snippet(title: "Greeting", body: "first")
        let first = try await store.saveSnippet(draft)
        let second = try await store.saveSnippet(draft)
        #expect(second.lamport == first.lamport + 1)
    }

    @Test func exhaustedNewRevisionCannotInsert() async throws {
        let store = try self.makeStore()
        let snippet = Snippet(title: "Exhausted", body: "draft", lamport: Int64.max)
        await #expect(throws: SnippetRevisionError.exhausted(id: snippet.id)) {
            try await store.saveSnippet(snippet)
        }
        #expect(try await store.snippets().isEmpty)
    }

    @Test(arguments: [false, true])
    func exhaustedStoredRevisionCannotSaveOrDelete(conditional: Bool) async throws {
        let store = try self.makeStore()
        let stored = try await store.saveSnippet(Snippet(title: "Exhausted", body: "original", lamport: Int64.max - 1))
        let baseline = try await store.snippets()
        var edited = stored
        edited.body = "unsaved draft"
        await #expect(throws: SnippetRevisionError.exhausted(id: stored.id)) {
            if conditional {
                try await store.saveSnippet(edited, expectedRevision: stored.lamport)
            } else {
                try await store.saveSnippet(edited)
            }
        }
        await #expect(throws: SnippetRevisionError.exhausted(id: stored.id)) {
            try await store.deleteSnippet(id: stored.id)
        }
        #expect(try await store.snippets() == baseline)
    }

    @Test func largestSafeRevisionAdvancesExactlyOnce() async throws {
        let store = try self.makeStore()
        let stored = try await store.saveSnippet(Snippet(title: "Boundary", body: "original", lamport: Int64.max - 2))
        #expect(stored.lamport == Int64.max - 1)
        let updated = try await store.saveSnippet(stored, expectedRevision: stored.lamport)
        #expect(updated.lamport == Int64.max)
    }
}
