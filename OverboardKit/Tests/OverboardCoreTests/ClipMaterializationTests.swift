import Foundation
@testable import OverboardCore
import Testing

struct ClipMaterializationTests {
    private func makeStore() throws -> ClipStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("materialization-\(UUID().uuidString)")
        return try ClipStore(dbWriter: OverboardDatabase.openInMemory(), blobs: BlobStore(directory: directory))
    }

    @Test func materializationPreservesRequestedClipAndInsertedRepresentationOrder() async throws {
        let store = try self.makeStore()
        let first = try #require(await store.ingest(PasteboardSnapshot(
            reps: [
                .init(uti: WellKnownUTI.html, data: Data("<p>one</p>".utf8)),
                .init(uti: WellKnownUTI.plainText, data: Data("one".utf8)),
            ], sourceBundleID: nil, sourceAppName: nil
        )))
        let second = try #require(await store.ingest(PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data("two".utf8))],
            sourceBundleID: nil, sourceAppName: nil
        )))
        let clips = try await store.materialize(itemIDs: [second.id, first.id])
        #expect(clips.map(\.item.id) == [second.id, first.id])
        #expect(clips[1].representations.map(\.representation.uti) == [WellKnownUTI.html, WellKnownUTI.plainText])
        #expect(clips[1].representations.map(\.payload) == [Data("<p>one</p>".utf8), Data("one".utf8)])
    }

    @Test func missingOrDeletedClipsRejectTheWholeMaterialization() async throws {
        let store = try self.makeStore()
        let clip = try #require(await store.ingest(PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data("one".utf8))],
            sourceBundleID: nil, sourceAppName: nil
        )))
        await #expect(throws: (any Error).self) {
            try await store.materialize(itemIDs: [clip.id, "missing"])
        }
        try await store.delete(id: clip.id)
        await #expect(throws: (any Error).self) {
            try await store.materialize(itemIDs: [clip.id])
        }
    }

    @Test func materializationPreservesMixedItemIdentityAndFlavorOrder() async throws {
        let store = try self.makeStore()
        let clip = try #require(await store.ingest(PasteboardSnapshot(
            reps: [
                .init(uti: WellKnownUTI.plainText, data: Data("second".utf8), itemIndex: 1),
                .init(uti: WellKnownUTI.html, data: Data("<b>first</b>".utf8), itemIndex: 0),
                .init(uti: WellKnownUTI.plainText, data: Data("first".utf8), itemIndex: 0),
            ], sourceBundleID: nil, sourceAppName: nil
        )))
        let materialized = try #require(await store.materialize(itemIDs: [clip.id]).first)
        #expect(materialized.representations.map(\.representation.itemIndex) == [0, 0, 1])
        #expect(materialized.representations.map(\.payload) == [
            Data("<b>first</b>".utf8), Data("first".utf8), Data("second".utf8),
        ])
        #expect(try await store.representations(for: clip.id).map(\.itemIndex) == [0, 0, 1])
    }

    @Test func oldRepresentationJSONDecodesWithoutAnItemIndex() throws {
        let representation = try JSONDecoder().decode(Representation.self, from: Data("""
        {"id":"rep","itemID":"clip","uti":"public.png","byteSize":3,"data":"AQID"}
        """.utf8))
        #expect(representation.itemIndex == nil)
        #expect(representation.data == Data([1, 2, 3]))
    }

    @Test func missingBlobThrowsBeforeReturningAnyClips() async throws {
        let store = try self.makeStore()
        let payload = Data(repeating: 0x42, count: Representation.inlineThreshold + 1)
        let clip = try #require(await store.ingest(PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.png, data: payload)], sourceBundleID: nil, sourceAppName: nil
        )))
        let representation = try #require(await store.representations(for: clip.id).first)
        let url = try #require(await store.blobURL(for: representation))
        try FileManager.default.removeItem(at: url)
        await #expect(throws: (any Error).self) {
            try await store.materialize(itemIDs: [clip.id])
        }
    }
}
