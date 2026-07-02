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

    private func insertPlainText(_ db: Database, itemID: String, _ text: String) throws {
        let data = Data(text.utf8)
        try db.execute(
            sql: """
            INSERT INTO representation (id, itemID, uti, data, byteSize)
            VALUES (?, ?, ?, ?, ?)
            """,
            arguments: ["rep-\(itemID)", itemID, WellKnownUTI.plainText, data, data.count]
        )
    }

    @Test func backfillsCountsForEachKind() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: "v1")

        try queue.write { db in
            let body = "line one\nline two\nline three" // 28 chars, 3 lines
            try self.insertItem(db, id: "text", kind: "text", searchText: body)
            try self.insertPlainText(db, itemID: "text", body)

            try self.insertItem(db, id: "link", kind: "link",
                                searchText: "https://example.com")
            try self.insertPlainText(db, itemID: "link", "https://example.com")

            try self.insertItem(db, id: "image", kind: "image",
                                previewText: "Image 1920×1080")

            try self.insertItem(db, id: "secret", kind: "text",
                                searchText: nil, isSecret: true)
            try self.insertPlainText(db, itemID: "secret", "super secret value")

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
            #expect(text.charCount == 28)
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

    /// Enrichment appends AI titles/summaries into searchText, so the backfill
    /// must count the plainText payload, not searchText.
    @Test func enrichedRowCountsPayloadNotSearchText() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: "v1")

        let body = String(repeating: "a", count: 300)
        try queue.write { db in
            try self.insertItem(db, id: "enriched", kind: "text",
                                searchText: body + "\nSome AI Title\nA whole summary sentence.")
            try self.insertPlainText(db, itemID: "enriched", body)
        }
        try Migrations.migrator.migrate(queue)

        try queue.read { db in
            let item = try #require(try ClipItem.fetchOne(db, key: "enriched"))
            #expect(item.charCount == 300)
            #expect(item.lineCount == 1)
        }
    }

    /// Blob-backed plainText payloads (>32 KB of text) aren't reachable in the
    /// migration — both counts stay NULL rather than store a truncated value.
    @Test func blobBackedTextStaysNull() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: "v1")

        try queue.write { db in
            try self.insertItem(db, id: "big", kind: "text",
                                searchText: String(repeating: "a", count: 100))
            try db.execute(
                sql: """
                INSERT INTO representation (id, itemID, uti, data, blobHash, byteSize)
                VALUES (?, ?, ?, NULL, ?, ?)
                """,
                arguments: ["rep-big", "big", WellKnownUTI.plainText, "cafebabe", 50000]
            )
        }
        try Migrations.migrator.migrate(queue)

        try queue.read { db in
            let item = try #require(try ClipItem.fetchOne(db, key: "big"))
            #expect(item.charCount == nil)
            #expect(item.lineCount == nil)
        }
    }
}
