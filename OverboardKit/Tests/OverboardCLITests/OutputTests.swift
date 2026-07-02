import Foundation
@testable import OverboardCLI
import OverboardCore
import Testing

/// The CLI's presentation layer is pure — it maps `ClipItem`s to JSON and text
/// without touching the database — so it's tested directly against fixtures.
struct OutputTests {
    /// A deterministic fixture with every field the JSON projection reads,
    /// including v4 provenance and stable dates.
    static func fixture(
        id: String = "clip-1",
        kind: ItemKind = .text,
        preview: String? = "hello world",
        isSecret: Bool = false,
        sourceURL: String? = "https://example.com/page"
    ) -> ClipItem {
        let created = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
        let used = Date(timeIntervalSince1970: 1_700_003_600) // +1h
        return ClipItem(
            id: id,
            contentHash: "hash-\(id)",
            kind: kind,
            previewText: preview,
            sourceBundleID: "com.example.App",
            sourceAppName: "Example",
            byteSize: 42,
            isPinned: true,
            isSecret: isSecret,
            useCount: 3,
            createdAt: created,
            lastUsedAt: used,
            updatedAt: used,
            sourceURL: sourceURL,
            sourceTitle: "Example Page"
        )
    }

    // MARK: - ClipJSON mapping

    @Test func clipJSONMapsEveryField() {
        let json = ClipJSON(Self.fixture())
        #expect(json.id == "clip-1")
        #expect(json.kind == "text")
        #expect(json.preview == "hello world")
        #expect(json.sourceApp == "Example")
        #expect(json.sourceBundleID == "com.example.App")
        #expect(json.sourceURL == "https://example.com/page")
        #expect(json.pinned == true)
        #expect(json.byteSize == 42)
        #expect(json.useCount == 3)
        #expect(json.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(json.lastUsedAt == Date(timeIntervalSince1970: 1_700_003_600))
    }

    @Test func sourceURLPassesThroughEncodedJSON() throws {
        let encoded = try Output.jsonArray([Self.fixture()])
        #expect(encoded.contains("\"sourceURL\" : \"https:\\/\\/example.com\\/page\""))
    }

    @Test func datesEncodeAsISO8601() throws {
        let encoded = try Output.jsonObject(Self.fixture())
        // .iso8601 renders createdAt at the UTC instant of the fixture.
        #expect(encoded.contains("\"createdAt\" : \"2023-11-14T22:13:20Z\""))
    }

    @Test func jsonKeysAreSorted() throws {
        let encoded = try Output.jsonObject(Self.fixture())
        let byteIndex = try #require(encoded.range(of: "\"byteSize\""))
        let idIndex = try #require(encoded.range(of: "\"id\""))
        // sortedKeys guarantees byteSize precedes id.
        #expect(byteIndex.lowerBound < idIndex.lowerBound)
    }

    // MARK: - Secret filtering

    @Test func visibleDropsSecrets() {
        let items = [
            Self.fixture(id: "a", isSecret: false),
            Self.fixture(id: "b", isSecret: true),
            Self.fixture(id: "c", isSecret: false),
        ]
        let visible = Output.visible(items)
        #expect(visible.map(\.id) == ["a", "c"])
    }

    @Test func visibleKeepsAllWhenNoSecrets() {
        let items = [Self.fixture(id: "a"), Self.fixture(id: "b")]
        #expect(Output.visible(items).count == 2)
    }

    // MARK: - Text formatting

    @Test func textLineHasIndexKindPreviewAndApp() {
        let now = Date(timeIntervalSince1970: 1_700_003_600)
        let line = Output.textLine(index: 1, item: Self.fixture(), now: now)
        #expect(line.hasPrefix("1. [text] hello world — Example · "))
    }

    @Test func textLineCollapsesNewlines() {
        let item = Self.fixture(preview: "line one\nline two")
        let line = Output.textLine(index: 2, item: item)
        #expect(line.contains("line one line two"))
        #expect(!line.contains("\n"))
    }

    @Test func textLineOmitsAppWhenMissing() {
        var item = Self.fixture()
        item.sourceAppName = nil
        let line = Output.textLine(index: 1, item: item)
        // No app segment, but the relative-age segment is always present.
        #expect(line.contains("[text] hello world — "))
        #expect(!line.contains("Example"))
    }

    @Test func textListNumbersFromOne() {
        let items = [Self.fixture(id: "a"), Self.fixture(id: "b")]
        let list = Output.textList(items)
        let lines = list.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("1. "))
        #expect(lines[1].hasPrefix("2. "))
    }
}
