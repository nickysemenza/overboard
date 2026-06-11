import Foundation
@testable import OverboardCore
import Testing

struct ClipSearchProviderTests {
    private func makeStore() throws -> ClipStore {
        let queue = try OverboardDatabase.openInMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-launcher-clips-\(UUID().uuidString)", isDirectory: true)
        return try ClipStore(dbWriter: queue, blobs: BlobStore(directory: dir))
    }

    private func snapshot(_ text: String) -> PasteboardSnapshot {
        PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data(text.utf8))],
            sourceBundleID: "dev.example.editor",
            sourceAppName: "Demo Editor"
        )
    }

    @Test func mapsMatchesToClipRows() async throws {
        let store = try makeStore()
        let ingested = try await store.ingest(self.snapshot("deploy checklist"))
        try await store.ingest(self.snapshot("grocery list"))

        let results = await ClipSearchProvider(store: store).results(for: "deploy")
        #expect(results.count == 1)
        guard case let .clip(item) = results.first else {
            Issue.record("expected a clip row, got \(results)")
            return
        }
        #expect(item.id == ingested?.id)
    }

    @Test func respectsLimit() async throws {
        let store = try makeStore()
        for index in 0 ..< 7 {
            try await store.ingest(self.snapshot("deploy note number \(index)"))
        }
        let results = await ClipSearchProvider(store: store, limit: 5).results(for: "deploy")
        #expect(results.count == 5)
    }

    @Test func excludesSecrets() async throws {
        let store = try makeStore()
        // FTS already hides secrets from text search, but a filter-only query
        // ("kind:text") lists straight off the item table — the provider must
        // drop them there too.
        let secret = try await store.ingest(self.snapshot("AKIAIOSFODNN7EXAMPLE"))
        #expect(secret?.isSecret == true)
        try await store.ingest(self.snapshot("harmless note"))

        let results = await ClipSearchProvider(store: store).results(for: "kind:text")
        #expect(results.count == 1)
        guard case let .clip(item) = results.first else {
            Issue.record("expected a clip row, got \(results)")
            return
        }
        #expect(!item.isSecret)
    }

    @Test func emptyForSingleCharacterQuery() async throws {
        let store = try makeStore()
        try await store.ingest(self.snapshot("a thing"))
        let results = await ClipSearchProvider(store: store).results(for: "a")
        #expect(results.isEmpty)
    }

    @Test func emptyForPunctuationOnlyQuery() async throws {
        let store = try makeStore()
        try await store.ingest(self.snapshot("recent thing"))
        // ClipStore.search falls back to recent() here; the provider must not
        // leak recent clips for a query that matches nothing.
        let results = await ClipSearchProvider(store: store).results(for: "??")
        #expect(results.isEmpty)
    }

    @Test func kindOperatorFilters() async throws {
        let store = try makeStore()
        try await store.ingest(self.snapshot("https://example.com"))
        try await store.ingest(self.snapshot("plain words"))

        let links = await ClipSearchProvider(store: store).results(for: "kind:link")
        #expect(links.count == 1)
        guard case let .clip(item) = links.first else {
            Issue.record("expected a clip row, got \(links)")
            return
        }
        #expect(item.kind == .link)
    }
}

struct SnippetSearchProviderTests {
    private func makeStore() throws -> ClipStore {
        let queue = try OverboardDatabase.openInMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-launcher-snippets-\(UUID().uuidString)", isDirectory: true)
        return try ClipStore(dbWriter: queue, blobs: BlobStore(directory: dir))
    }

    @Test func mapsMatchesToSnippetRows() async throws {
        let store = try makeStore()
        try await store.saveSnippet(Snippet(title: "Standup", body: "Yesterday / Today / Blockers"))
        try await store.saveSnippet(Snippet(title: "Address", body: "123 Main St"))

        let results = await SnippetSearchProvider(store: store).results(for: "standup")
        #expect(results.count == 1)
        guard case let .snippet(snippet) = results.first else {
            Issue.record("expected a snippet row, got \(results)")
            return
        }
        #expect(snippet.title == "Standup")
    }

    @Test func respectsLimit() async throws {
        let store = try makeStore()
        for index in 0 ..< 5 {
            try await store.saveSnippet(Snippet(title: "Greeting \(index)", body: "Hello"))
        }
        let results = await SnippetSearchProvider(store: store, limit: 3).results(for: "greeting")
        #expect(results.count == 3)
    }

    @Test func emptyForShortQuery() async throws {
        let store = try makeStore()
        try await store.saveSnippet(Snippet(title: "Standup", body: "notes"))
        // searchSnippets("") would return every snippet — the provider must
        // require a real query.
        #expect(await SnippetSearchProvider(store: store).results(for: "s").isEmpty)
        #expect(await SnippetSearchProvider(store: store).results(for: "").isEmpty)
    }

    @Test func ranksTitleMatchesAboveBodyMatches() async throws {
        let store = try makeStore()
        // Saved in title-alphabetical order: Address (body hit), My signature
        // (title word prefix), Signature (title prefix) — ranking must invert
        // the store's order.
        try await store.saveSnippet(Snippet(title: "Address", body: "signature dish: paella"))
        try await store.saveSnippet(Snippet(title: "My signature", body: "Cheers"))
        try await store.saveSnippet(Snippet(title: "Signature block", body: "Best"))

        let results = await SnippetSearchProvider(store: store).results(for: "signature")
        let titles = results.compactMap { result -> String? in
            guard case let .snippet(snippet) = result else { return nil }
            return snippet.title
        }
        #expect(titles == ["Signature block", "My signature", "Address"])
    }

    @Test func rankTiers() {
        let query = "sig"
        func snippet(_ title: String, body: String = "x") -> Snippet {
            Snippet(title: title, body: body)
        }
        #expect(SnippetSearchProvider.rank(snippet("Signature"), query: query) == 0)
        #expect(SnippetSearchProvider.rank(snippet("Email sig"), query: query) == 1)
        #expect(SnippetSearchProvider.rank(snippet("Designs"), query: query) == 2)
        #expect(SnippetSearchProvider.rank(snippet("Other", body: "sig here"), query: query) == 3)
    }
}
