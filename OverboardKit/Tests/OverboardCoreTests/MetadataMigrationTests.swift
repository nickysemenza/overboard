import Foundation
import GRDB
@testable import OverboardCore
import Testing

/// Exercises the v2 backfill against raw v1-shaped rows: staged migration to
/// "v1", insert the pre-migration shape, then migrate the rest and assert.
struct MetadataMigrationTests {
    private func insertItem(
        _ db: Database, id: String, kind: String,
        previewText: String? = nil, searchText: String? = nil,
        byteSize: Int = 0, isSecret: Bool = false
    ) throws {
        let now = Date()
        try db.execute(
            sql: """
            INSERT INTO item (id, contentHash, kind, previewText, searchText,
                              byteSize, isSecret, useCount, createdAt, lastUsedAt,
                              updatedAt, lamport)
            VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, 0)
            """,
            arguments: [id, "hash-\(id)", kind, previewText, searchText,
                        byteSize, isSecret, now, now, now]
        )
    }

    @Test func backfillsCountsForEachKind() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: "v1")

        try queue.write { db in
            try self.insertItem(db, id: "text", kind: "text",
                                searchText: "line one\nline two\nline three") // 3 lines
            try self.insertItem(db, id: "link", kind: "link",
                                searchText: "https://example.com")
            try self.insertItem(db, id: "image", kind: "image",
                                previewText: "Image 1920×1080")
            try self.insertItem(db, id: "secret", kind: "text",
                                searchText: "super secret value", isSecret: true)

            // Inline file rep: JSON array of two URLs.
            try self.insertItem(db, id: "file", kind: "file", byteSize: 4096)
            let urls = try JSONEncoder().encode([
                URL(fileURLWithPath: "/tmp/a.pdf").absoluteString,
                URL(fileURLWithPath: "/tmp/b.txt").absoluteString,
            ])
            try db.execute(
                sql: """
                INSERT INTO representation (id, itemID, uti, data, byteSize)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: ["rep-file", "file", WellKnownUTI.fileURLs, urls, urls.count]
            )

            // Blob-backed file rep (data IS NULL) must stay NULL.
            try self.insertItem(db, id: "blobfile", kind: "file")
            try db.execute(
                sql: """
                INSERT INTO representation (id, itemID, uti, data, blobHash, byteSize)
                VALUES (?, ?, ?, NULL, ?, ?)
                """,
                arguments: ["rep-blob", "blobfile", WellKnownUTI.fileURLs, "deadbeef", 99999]
            )
        }

        try Migrations.migrator.migrate(queue)

        try queue.read { db in
            let text = try #require(try ClipItem.fetchOne(db, key: "text"))
            #expect(text.charCount == 28) // full searchText length
            #expect(text.lineCount == 3)

            let link = try #require(try ClipItem.fetchOne(db, key: "link"))
            #expect(link.charCount == 19)
            #expect(link.lineCount == 1)

            let image = try #require(try ClipItem.fetchOne(db, key: "image"))
            #expect(image.pixelWidth == 1920)
            #expect(image.pixelHeight == 1080)

            let secret = try #require(try ClipItem.fetchOne(db, key: "secret"))
            #expect(secret.charCount == nil)
            #expect(secret.lineCount == nil)

            let file = try #require(try ClipItem.fetchOne(db, key: "file"))
            #expect(file.fileCount == 2)

            let blobfile = try #require(try ClipItem.fetchOne(db, key: "blobfile"))
            #expect(blobfile.fileCount == nil)
        }
    }

    @Test func cappedSearchTextStaysNull() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: "v1")

        // A row exactly at the cap was truncated on capture, so its length would
        // be a lie — the backfill must leave charCount NULL.
        let capped = String(repeating: "a", count: CaptureClassifier.searchTextLimit)
        try queue.write { db in
            try self.insertItem(db, id: "capped", kind: "text", searchText: capped)
        }
        try Migrations.migrator.migrate(queue)

        try queue.read { db in
            let item = try #require(try ClipItem.fetchOne(db, key: "capped"))
            #expect(item.charCount == nil)
            #expect(item.lineCount == 1) // lineCount is still computed
        }
    }
}
