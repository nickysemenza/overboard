import Foundation
import GRDB
@testable import OverboardCore
import Testing

/// Verifies the v4 provenance migration applies cleanly over a v3-shaped
/// database: stage migration to "v3", insert a pre-v4 row, migrate the rest,
/// then confirm the new columns exist and round-trip (no backfill expected).
struct ProvenanceMigrationTests {
    @Test func v4AddsProvenanceColumnsOverV3DB() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: "v3")

        // A row inserted before v4 has no sourceURL/sourceTitle columns yet.
        let now = Date()
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO item (id, contentHash, kind, previewText, byteSize,
                                  isSecret, useCount, createdAt, lastUsedAt, updatedAt, lamport)
                VALUES (?, ?, 'link', ?, 0, 0, 1, ?, ?, ?, 0)
                """,
                arguments: ["pre-v4", "hash", "https://example.com", now, now, now]
            )
        }

        // Apply the remaining migrations (v4).
        try Migrations.migrator.migrate(queue)

        try queue.read { db in
            let item = try #require(try ClipItem.fetchOne(db, key: "pre-v4"))
            // No backfill: existing rows have NULL provenance.
            #expect(item.sourceURL == nil)
            #expect(item.sourceTitle == nil)
        }

        // The columns are writable/readable post-migration.
        try queue.write { db in
            try db.execute(
                sql: "UPDATE item SET sourceURL = ?, sourceTitle = ? WHERE id = ?",
                arguments: ["https://example.com/page", "A Page", "pre-v4"]
            )
        }
        try queue.read { db in
            let item = try #require(try ClipItem.fetchOne(db, key: "pre-v4"))
            #expect(item.sourceURL == "https://example.com/page")
            #expect(item.sourceTitle == "A Page")
        }
    }
}
