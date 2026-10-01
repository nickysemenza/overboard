import Foundation
@testable import OverboardCore
import Testing

struct CaptureClassifierDedupeTests {
    private func classify(_ reps: [PasteboardSnapshot.Rep]) throws -> CaptureClassifier.Classified {
        try #require(CaptureClassifier.classify(PasteboardSnapshot(
            reps: reps, sourceBundleID: nil, sourceAppName: nil
        )))
    }

    @Test func secondaryRichFlavorChangesIdentity() throws {
        let text = PasteboardSnapshot.Rep(uti: WellKnownUTI.plainText, data: Data("hello".utf8))
        let bold = try self.classify([text, .init(uti: WellKnownUTI.html, data: Data("<b>hello</b>".utf8))])
        let italic = try self.classify([text, .init(uti: WellKnownUTI.html, data: Data("<i>hello</i>".utf8))])
        let plain = try self.classify([text])
        #expect(bold.contentHash != italic.contentHash)
        #expect(bold.contentHash != plain.contentHash)
        #expect(bold.previewText == italic.previewText)
    }

    @Test func representationOrderDoesNotChangeIdentity() throws {
        let reps: [PasteboardSnapshot.Rep] = [
            .init(uti: WellKnownUTI.plainText, data: Data("hello".utf8)),
            .init(uti: WellKnownUTI.rtf, data: Data("{\\rtf1 hello}".utf8)),
            .init(uti: WellKnownUTI.html, data: Data("<b>hello</b>".utf8)),
        ]
        #expect(try self.classify(reps).contentHash == self.classify(reps.reversed()).contentHash)
    }

    @Test func secondaryFlavorsOfSecretsAlsoChangeIdentity() throws {
        let text = PasteboardSnapshot.Rep(
            uti: WellKnownUTI.plainText, data: Data("https://example.com/?access_token=secret".utf8)
        )
        let first = try self.classify([text, .init(uti: WellKnownUTI.html, data: Data("one".utf8))])
        let second = try self.classify([text, .init(uti: WellKnownUTI.html, data: Data("two".utf8))])
        #expect(first.isSecret)
        #expect(second.isSecret)
        #expect(first.contentHash != second.contentHash)
        #expect(first.searchText == nil)
    }

    @Test func representationBoundariesAreUnambiguous() throws {
        let text = PasteboardSnapshot.Rep(uti: WellKnownUTI.plainText, data: Data("hello".utf8))
        let first = try self.classify([text, .init(uti: "custom.a", data: Data("bc".utf8))])
        let second = try self.classify([text, .init(uti: "custom.ab", data: Data("c".utf8))])
        #expect(first.contentHash != second.contentHash)
    }

    @Test func pasteboardItemOrderChangesIdentity() throws {
        let first: [PasteboardSnapshot.Rep] = [
            .init(uti: WellKnownUTI.plainText, data: Data("first".utf8), itemIndex: 0),
            .init(uti: WellKnownUTI.plainText, data: Data("second".utf8), itemIndex: 1),
        ]
        let second: [PasteboardSnapshot.Rep] = [
            .init(uti: WellKnownUTI.plainText, data: Data("first".utf8), itemIndex: 1),
            .init(uti: WellKnownUTI.plainText, data: Data("second".utf8), itemIndex: 0),
        ]
        #expect(try self.classify(first).contentHash != self.classify(second).contentHash)
        #expect(try self.classify(first).contentHash == self.classify(first.reversed()).contentHash)
    }

    @Test func itemFlavorGroupingChangesIdentity() throws {
        let text = PasteboardSnapshot.Rep(uti: WellKnownUTI.plainText, data: Data("hello".utf8), itemIndex: 0)
        let together = try self.classify([
            text,
            .init(uti: WellKnownUTI.html, data: Data("<b>hello</b>".utf8), itemIndex: 0),
        ])
        let separate = try self.classify([
            text,
            .init(uti: WellKnownUTI.html, data: Data("<b>hello</b>".utf8), itemIndex: 1),
        ])
        #expect(together.contentHash != separate.contentHash)
    }

    @Test func legacyFlavorGroupMatchesSingleIndexedItem() throws {
        let legacy = try self.classify([.init(uti: WellKnownUTI.plainText, data: Data("hello".utf8))])
        let indexed = try self.classify([.init(uti: WellKnownUTI.plainText, data: Data("hello".utf8), itemIndex: 0)])
        #expect(legacy.contentHash == indexed.contentHash)
    }

    @Test func indexedFileURLsRetainAggregateMetadata() throws {
        let files = try self.classify([
            .init(uti: WellKnownUTI.fileURLs, data: JSONEncoder().encode(["file:///tmp/first.txt"]), itemIndex: 0),
            .init(uti: WellKnownUTI.fileURLs, data: JSONEncoder().encode(["file:///tmp/second.txt"]), itemIndex: 1),
        ])
        #expect(files.kind == .file)
        #expect(files.fileCount == 2)
        #expect(files.previewText == "first.txt, second.txt")
    }

    @Test func richVariantsRemainSeparateStoreItems() async throws {
        let queue = try OverboardDatabase.openInMemory()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try ClipStore(dbWriter: queue, blobs: BlobStore(directory: directory))
        let variants = ["<b>hello</b>", "<i>hello</i>"].map { html in
            PasteboardSnapshot(
                reps: [
                    .init(uti: WellKnownUTI.plainText, data: Data("hello".utf8)),
                    .init(uti: WellKnownUTI.html, data: Data(html.utf8)),
                ],
                sourceBundleID: nil, sourceAppName: nil
            )
        }
        let first = try #require(await store.ingest(variants[0]))
        let second = try #require(await store.ingest(variants[1]))
        #expect(first.id != second.id)
        #expect(try await store.recent().count == 2)
    }
}
