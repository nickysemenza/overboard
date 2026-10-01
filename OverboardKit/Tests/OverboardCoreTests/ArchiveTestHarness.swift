import Foundation
import GRDB
@testable import OverboardCore
import Testing

struct ArchiveImageFixture {
    let item: ClipItem
    let hash: String
    let bytes: Data
}

struct ArchiveHarness {
    let root: URL
    let database: DatabaseQueue
    let store: ClipStore
    let blobs: BlobStore

    init() throws {
        self.root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("secure-archive-\(UUID().uuidString)")
        self.blobs = try BlobStore(directory: self.root.appendingPathComponent("managed-blobs"))
        self.database = try OverboardDatabase.openInMemory()
        self.store = ClipStore(dbWriter: self.database, blobs: self.blobs)
    }

    var archive: URL {
        self.root.appendingPathComponent("archive")
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.root)
    }

    @discardableResult
    func text(_ text: String) async throws -> ClipItem {
        try #require(await self.store.ingest(.init(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data(text.utf8))],
            sourceBundleID: nil, sourceAppName: nil
        )))
    }

    func image() async throws -> ArchiveImageFixture {
        let bytes = Data(repeating: 0x42, count: Representation.inlineThreshold + 17)
        let item = try #require(await self.store.ingest(.init(
            reps: [.init(uti: WellKnownUTI.png, data: bytes)], sourceBundleID: nil, sourceAppName: nil
        )))
        let hash = try #require(try await self.store.representations(for: item.id).first?.blobHash)
        return ArchiveImageFixture(item: item, hash: hash, bytes: bytes)
    }

    func rewriteFirstRecord(_ update: (inout ClipArchive.Record) -> Void, legacy: Bool = false) throws {
        let url = self.archive.appendingPathComponent(ClipArchive.itemsFileName)
        var records = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try ClipJSONCoding.archiveDecoder().decode(ClipArchive.Record.self, from: Data($0.utf8))
        }
        update(&records[0])
        var data = Data()
        for record in records {
            try data.append(ClipJSONCoding.archiveEncoder().encode(record)); data.append(0x0A)
        }
        try data.write(to: url)
        let manifestURL = self.archive.appendingPathComponent(ClipArchive.manifestFileName)
        if legacy {
            try FileManager.default.removeItem(at: manifestURL)
        } else {
            var manifest = try ClipJSONCoding.archiveDecoder().decode(
                ClipArchive.Manifest.self,
                from: Data(contentsOf: manifestURL)
            )
            manifest.itemsChecksum = BlobStore.hash(data)
            try ClipJSONCoding.archiveEncoder().encode(manifest).write(to: manifestURL)
        }
    }
}
