import Foundation
import OverboardCore
@testable import OverboardUI
import Testing

/// Pure view-model logic, not rendering — doesn't need `.localOnly` and runs
/// everywhere `swift test` does.
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
}
