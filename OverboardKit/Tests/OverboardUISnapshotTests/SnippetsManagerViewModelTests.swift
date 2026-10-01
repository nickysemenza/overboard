import Foundation
import OverboardCore
@testable import OverboardUI
import Testing

/// Pure view-model logic, not rendering — no snapshot references involved.
@MainActor
struct SnippetsManagerViewModelTests {
    private func makeStore() throws -> ClipStore {
        let queue = try OverboardDatabase.openInMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-snippet-vm-\(UUID().uuidString)", isDirectory: true)
        return try ClipStore(dbWriter: queue, blobs: BlobStore(directory: dir))
    }

    @Test func switchingSelectionAutoSavesADirtyDraft() async throws {
        let store = try makeStore()
        let first = Snippet(title: "First", body: "one")
        let second = Snippet(title: "Second", body: "two")
        try await store.saveSnippet(first)
        try await store.saveSnippet(second)

        let viewModel = SnippetsManagerViewModel(store: store)
        await viewModel.load()
        viewModel.selectSnippet(first.id)
        viewModel.draftBody = "one, edited"

        viewModel.selectSnippet(second.id)
        // Selection switched...
        #expect(viewModel.selectedID == second.id)
        // ...and the outgoing edit was saved rather than dropped. The save
        // runs on a background Task; await it directly instead of guessing
        // at a sleep duration.
        await viewModel.pendingSaveTask?.value
        let saved = try await store.snippets().first { $0.id == first.id }
        #expect(saved?.body == "one, edited")
    }

    @Test func emptyTitleIsNotAutoSaved() async throws {
        let store = try makeStore()
        let first = Snippet(title: "First", body: "one")
        let second = Snippet(title: "Second", body: "two")
        try await store.saveSnippet(first)
        try await store.saveSnippet(second)

        let viewModel = SnippetsManagerViewModel(store: store)
        await viewModel.load()
        viewModel.selectSnippet(first.id)
        viewModel.draftTitle = ""
        viewModel.draftBody = "should not be persisted"

        viewModel.selectSnippet(second.id)

        // Nothing should have been scheduled to persist.
        #expect(viewModel.pendingSaveTask == nil)
        let saved = try await store.snippets().first { $0.id == first.id }
        #expect(saved?.title == "First")
        #expect(saved?.body == "one")
    }

    @Test func cleanSelectionDoesNotWriteOnSwitch() async throws {
        let store = try makeStore()
        let first = Snippet(title: "First", body: "one")
        let second = Snippet(title: "Second", body: "two")
        try await store.saveSnippet(first)
        try await store.saveSnippet(second)

        let viewModel = SnippetsManagerViewModel(store: store)
        await viewModel.load()
        viewModel.selectSnippet(first.id)
        #expect(!viewModel.isDirty)

        viewModel.selectSnippet(second.id)
        #expect(viewModel.pendingSaveTask == nil)
        #expect(viewModel.draftTitle == "Second")
        #expect(viewModel.draftBody == "two")
    }

    @Test func explicitSaveFallsBackToUntitledOnAnEmptyTitle() async throws {
        let store = try makeStore()
        let snippet = Snippet(title: "Original", body: "body")
        try await store.saveSnippet(snippet)

        let viewModel = SnippetsManagerViewModel(store: store)
        await viewModel.load()
        viewModel.selectSnippet(snippet.id)
        viewModel.draftTitle = ""
        viewModel.saveDraft()

        await viewModel.pendingSaveTask?.value
        let saved = try await store.snippets().first { $0.id == snippet.id }
        #expect(saved?.title == "Untitled")
    }

    @Test func conflictedDraftAndVisibleErrorSurviveReloadAndSelectionChanges() async throws {
        let store = try self.makeStore()
        let first = try await store.saveSnippet(Snippet(title: "First", body: "one"))
        let second = try await store.saveSnippet(Snippet(title: "Second", body: "two"))
        let viewModel = SnippetsManagerViewModel(store: store)
        await viewModel.load()
        viewModel.selectSnippet(first.id)
        viewModel.draftBody = "local edit"
        var elsewhere = first
        elsewhere.body = "external edit"
        try await store.saveSnippet(elsewhere, expectedRevision: first.lamport)
        viewModel.saveDraft()
        await viewModel.pendingSaveTask?.value
        #expect(viewModel.saveError != nil)
        #expect(viewModel.isDirty)
        #expect(viewModel.draftBody == "local edit")
        await viewModel.load()
        #expect(viewModel.draftBody == "local edit")
        viewModel.selectSnippet(second.id)
        await viewModel.pendingSaveTask?.value
        viewModel.selectSnippet(first.id)
        #expect(viewModel.draftBody == "local edit")
        #expect(viewModel.saveError != nil)
        #expect(try await store.snippets().first(where: { $0.id == first.id })?.body == "external edit")
    }

    @Test func emptyTitleDraftIsPreservedWhenSwitchingBack() async throws {
        let store = try self.makeStore()
        let first = try await store.saveSnippet(Snippet(title: "First", body: "one"))
        let second = try await store.saveSnippet(Snippet(title: "Second", body: "two"))
        let viewModel = SnippetsManagerViewModel(store: store)
        await viewModel.load()
        viewModel.selectSnippet(first.id)
        viewModel.draftTitle = ""
        viewModel.draftBody = "unfinished"
        viewModel.selectSnippet(second.id)
        viewModel.selectSnippet(first.id)
        #expect(viewModel.draftTitle.isEmpty)
        #expect(viewModel.draftBody == "unfinished")
        #expect(viewModel.isDirty)
    }

    @Test func insertingATokenEditsOnlyTheDraftAndPreviewKeepsUUIDVisible() async throws {
        let store = try self.makeStore()
        let snippet = try await store.saveSnippet(Snippet(title: "Template", body: "Hello "))
        let viewModel = SnippetsManagerViewModel(store: store)
        await viewModel.load()
        viewModel.selectSnippet(snippet.id)
        viewModel.insertToken("{{name|world}}")
        viewModel.insertToken("{uuid}")
        #expect(viewModel.draftBody == "Hello {{name|world}}{uuid}")
        #expect(viewModel.previewText == "Hello world{uuid}")
        #expect(viewModel.isDirty)
        #expect(try await store.snippets().first?.body == "Hello ")
    }
}
