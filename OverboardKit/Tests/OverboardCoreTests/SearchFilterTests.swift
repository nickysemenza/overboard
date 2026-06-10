import Foundation
@testable import OverboardCore
import Testing

struct ParsedQueryTests {
    @Test func parsesOperatorsAndText() {
        let parsed = ParsedQuery.parse("deploy notes kind:text app:Claude category:code")
        #expect(parsed.text == "deploy notes")
        #expect(parsed.kind == .text)
        #expect(parsed.app == "Claude")
        #expect(parsed.category == "code")
    }

    @Test func kindAliases() {
        #expect(ParsedQuery.parse("kind:img").kind == .image)
        #expect(ParsedQuery.parse("kind:screenshot").kind == .image)
        #expect(ParsedQuery.parse("kind:url").kind == .link)
        #expect(ParsedQuery.parse("kind:files").kind == .file)
    }

    @Test func unknownOperatorStaysAsText() {
        let parsed = ParsedQuery.parse("kind:nonsense hello")
        #expect(parsed.kind == nil)
        #expect(parsed.text == "kind:nonsense hello")
    }

    @Test func plainQueryHasNoFilters() {
        let parsed = ParsedQuery.parse("just words")
        #expect(!parsed.hasFilters)
        #expect(parsed.text == "just words")
    }

    @Test func matchesChecksAllFilters() {
        let item = ClipItem(
            contentHash: "h", kind: .text, previewText: "p",
            sourceBundleID: "com.anthropic.claude", sourceAppName: "Claude",
            byteSize: 1, category: "code",
            createdAt: Date(), lastUsedAt: Date(), updatedAt: Date()
        )
        #expect(ParsedQuery.parse("app:claude").matches(item))
        #expect(ParsedQuery.parse("app:anthropic").matches(item))
        #expect(!ParsedQuery.parse("app:safari").matches(item))
        #expect(ParsedQuery.parse("kind:text category:code").matches(item))
        #expect(!ParsedQuery.parse("kind:image").matches(item))
    }
}

struct FilteredSearchTests {
    private func makeStore() throws -> ClipStore {
        let queue = try OverboardDatabase.openInMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-filter-\(UUID().uuidString)", isDirectory: true)
        return try ClipStore(dbWriter: queue, blobs: BlobStore(directory: dir))
    }

    private func snapshot(_ text: String, app: String, bundleID: String) -> PasteboardSnapshot {
        PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data(text.utf8))],
            sourceBundleID: bundleID,
            sourceAppName: app
        )
    }

    @Test func filtersByAppCombinedWithText() async throws {
        let store = try makeStore()
        try await store.ingest(self.snapshot("deploy checklist one", app: "Claude", bundleID: "com.anthropic.claude"))
        try await store.ingest(self.snapshot("deploy checklist two", app: "Safari", bundleID: "com.apple.Safari"))

        let all = try await store.search("deploy")
        #expect(all.count == 2)

        let claudeOnly = try await store.search("deploy app:claude")
        #expect(claudeOnly.count == 1)
        #expect(claudeOnly.first?.sourceAppName == "Claude")
    }

    @Test func kindFilterAloneListsByRecency() async throws {
        let store = try makeStore()
        try await store.ingest(self.snapshot("some text", app: "A", bundleID: "a"))
        let urlSnapshot = PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data("https://example.com".utf8))],
            sourceBundleID: "b",
            sourceAppName: "B"
        )
        try await store.ingest(urlSnapshot)

        let links = try await store.search("kind:link")
        #expect(links.count == 1)
        #expect(links.first?.kind == .link)

        let texts = try await store.search("kind:text")
        #expect(texts.count == 1)
    }

    @Test func plainSearchUnaffected() async throws {
        let store = try makeStore()
        try await store.ingest(self.snapshot("the quick brown fox", app: "A", bundleID: "a"))
        #expect(try await store.search("fox").count == 1)
        #expect(try await store.search("").count == 1) // falls back to recent
    }
}
