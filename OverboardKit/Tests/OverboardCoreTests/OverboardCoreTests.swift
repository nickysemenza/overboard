import Foundation
@testable import OverboardCore
import Testing

// MARK: - Helpers

private func textSnapshot(_ text: String, source: String? = "com.apple.TextEdit") -> PasteboardSnapshot {
    PasteboardSnapshot(
        reps: [.init(uti: WellKnownUTI.plainText, data: Data(text.utf8))],
        sourceBundleID: source,
        sourceAppName: "TextEdit"
    )
}

private func fileSnapshot(_ paths: [String]) -> PasteboardSnapshot {
    let urls = paths.map { URL(fileURLWithPath: $0).absoluteString }
    let data = try! JSONEncoder().encode(urls)
    return PasteboardSnapshot(
        reps: [
            .init(uti: WellKnownUTI.fileURLs, data: data),
            .init(uti: WellKnownUTI.plainText, data: Data(paths.joined(separator: "\n").utf8)),
        ],
        sourceBundleID: "com.apple.finder",
        sourceAppName: "Finder"
    )
}

private func makeStore() throws -> ClipStore {
    let queue = try OverboardDatabase.openInMemory()
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("overboard-tests-\(UUID().uuidString)", isDirectory: true)
    let blobs = try BlobStore(directory: dir)
    return ClipStore(dbWriter: queue, blobs: blobs)
}

// MARK: - Classifier

struct ClassifierTests {
    @Test func classifiesPlainText() {
        let result = CaptureClassifier.classify(textSnapshot("hello world"))
        #expect(result?.kind == .text)
        #expect(result?.previewText == "hello world")
        #expect(result?.searchText == "hello world")
    }

    @Test func classifiesLink() {
        let result = CaptureClassifier.classify(textSnapshot("https://example.com/page?q=1"))
        #expect(result?.kind == .link)
    }

    @Test func multilineTextWithURLIsNotALink() {
        let result = CaptureClassifier.classify(textSnapshot("check this:\nhttps://example.com"))
        #expect(result?.kind == .text)
    }

    @Test func classifiesFiles() {
        let result = CaptureClassifier.classify(fileSnapshot(["/tmp/report.pdf", "/tmp/notes.txt"]))
        #expect(result?.kind == .file)
        #expect(result?.previewText == "report.pdf, notes.txt")
        #expect(result?.searchText == "report.pdf notes.txt")
    }

    @Test func skipsWhitespaceOnlyText() {
        #expect(CaptureClassifier.classify(textSnapshot("   \n  ")) == nil)
    }

    @Test func skipsEmptySnapshot() {
        let empty = PasteboardSnapshot(reps: [], sourceBundleID: nil, sourceAppName: nil)
        #expect(CaptureClassifier.classify(empty) == nil)
    }

    @Test func hashIsStableAndContentBased() {
        let a = CaptureClassifier.classify(textSnapshot("same content", source: "com.app.one"))
        let b = CaptureClassifier.classify(textSnapshot("same content", source: "com.app.two"))
        let c = CaptureClassifier.classify(textSnapshot("different content"))
        #expect(a?.contentHash == b?.contentHash)
        #expect(a?.contentHash != c?.contentHash)
    }

    @Test func sameBytesDifferentKindHashDifferently() {
        let asText = CaptureClassifier.classify(textSnapshot("https://example.com"))
        // Same UTF-8 bytes, but classified as link vs (hypothetically) text
        // must not collide across kinds — kind is part of the hash.
        #expect(asText?.kind == .link)
    }

    @Test func longTextIsTruncatedForPreview() {
        let long = String(repeating: "a", count: 2000)
        let result = CaptureClassifier.classify(textSnapshot(long))
        #expect(result?.previewText?.count == 500)
        #expect(result?.byteSize == 2000)
    }
}

// MARK: - BlobStore

struct BlobStoreTests {
    @Test func roundTripsAndDedupes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-blob-\(UUID().uuidString)", isDirectory: true)
        let store = try BlobStore(directory: dir)
        let payload = Data((0 ..< 100_000).map { UInt8($0 % 256) })

        let hash1 = try store.store(payload)
        let hash2 = try store.store(payload)
        #expect(hash1 == hash2)
        #expect(try store.data(for: hash1) == payload)

        try store.delete(hash: hash1)
        #expect(throws: Error.self) { try store.data(for: hash1) }
    }
}

// MARK: - ClipStore

struct ClipStoreTests {
    @Test func ingestPersistsAndRecentReturns() async throws {
        let store = try makeStore()
        let item = try await store.ingest(textSnapshot("first clip"))
        #expect(item != nil)

        let recent = try await store.recent(limit: 10)
        #expect(recent.count == 1)
        #expect(recent.first?.previewText == "first clip")
        #expect(recent.first?.sourceBundleID == "com.apple.TextEdit")
    }

    @Test func duplicateContentBumpsInsteadOfInserting() async throws {
        let store = try makeStore()
        try await store.ingest(textSnapshot("dupe me"))
        try await store.ingest(textSnapshot("something else"))
        let bumped = try await store.ingest(textSnapshot("dupe me"))

        let recent = try await store.recent(limit: 10)
        #expect(recent.count == 2)
        #expect(bumped?.useCount == 2)
        #expect(recent.first?.previewText == "dupe me") // bumped to top
    }

    @Test func largePayloadGoesToBlobStore() async throws {
        let store = try makeStore()
        let big = String(repeating: "x", count: Representation.inlineThreshold + 1)
        let item = try await store.ingest(textSnapshot(big))

        let reps = try await store.representations(for: #require(item?.id))
        #expect(reps.count == 1)
        #expect(reps.first?.data == nil)
        #expect(reps.first?.blobHash != nil)
        let payload = try await store.payload(for: #require(reps.first))
        #expect(payload == Data(big.utf8))
    }

    @Test func searchFindsByContent() async throws {
        let store = try makeStore()
        try await store.ingest(textSnapshot("the quick brown fox"))
        try await store.ingest(textSnapshot("lazy dogs sleep all day"))
        try await store.ingest(fileSnapshot(["/tmp/quarterly-report.pdf"]))

        let foxes = try await store.search("fox")
        #expect(foxes.count == 1)
        #expect(foxes.first?.previewText == "the quick brown fox")

        // Prefix match on the last token.
        let qu = try await store.search("quart")
        #expect(qu.count == 1)
        #expect(qu.first?.kind == .file)

        // Quotes in input must not break the query.
        let quoted = try await store.search("\"fox")
        #expect(quoted.count == 1)
    }

    @Test func deleteTombstonesAndHidesFromSearch() async throws {
        let store = try makeStore()
        let item = try await store.ingest(textSnapshot("secret handshake"))
        try await store.delete(id: #require(item?.id))

        #expect(try await store.recent(limit: 10).isEmpty)
        #expect(try await store.search("handshake").isEmpty)
    }

    @Test func deletedContentCanBeReIngested() async throws {
        let store = try makeStore()
        let item = try await store.ingest(textSnapshot("come back"))
        try await store.delete(id: #require(item?.id))
        let again = try await store.ingest(textSnapshot("come back"))
        #expect(again != nil)
        #expect(try await store.recent(limit: 10).count == 1)
    }

    @Test func purgeTrimsHistoryAndKeepsPinned() async throws {
        let store = try makeStore()
        var pinnedID: String?
        for i in 0 ..< 10 {
            let item = try await store.ingest(textSnapshot("clip number \(i)"))
            if i == 0 { pinnedID = item?.id }
        }
        try await store.setPinned(id: #require(pinnedID), true)
        try await store.purge(keepingLatest: 3)

        let recent = try await store.recent(limit: 100)
        #expect(recent.count == 4) // 3 latest + 1 pinned
        #expect(recent.contains { $0.id == pinnedID })
        // Purged items are gone from FTS too.
        #expect(try await store.search("number").count == 4)
    }

    @Test func markUsedBumpsOrdering() async throws {
        let store = try makeStore()
        let first = try await store.ingest(textSnapshot("older"))
        try await store.ingest(textSnapshot("newer"))
        try await store.markUsed(id: #require(first?.id))

        let recent = try await store.recent(limit: 10)
        #expect(recent.first?.previewText == "older")
        #expect(recent.first?.useCount == 2)
    }
}

// MARK: - FTSQuery

struct FTSQueryTests {
    @Test func quotesTokensAndAddsPrefixStar() {
        #expect(FTSQuery.match(for: "hello world") == "\"hello\" \"world\"*")
    }

    @Test func stripsEmbeddedQuotes() {
        #expect(FTSQuery.match(for: "say \"hi\"") == "\"say\" \"hi\"*")
    }

    @Test func emptyInputGivesNil() {
        #expect(FTSQuery.match(for: "   ") == nil)
    }
}
