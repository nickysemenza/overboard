import Foundation
import GRDB
@testable import OverboardCore
import Testing

/// The v5 migration retroactively masks credential-bearing link clips captured
/// before capture-time detection existed. Tests the extracted reclassification
/// against hand-seeded legacy rows (openInMemory already ran the migration on an
/// empty DB, so we exercise the logic directly).
struct LinkSecretMigrationTests {
    @Test func reclassifiesExistingCredentialLinksButLeavesOrdinaryOnes() throws {
        let queue = try OverboardDatabase.openInMemory()
        try queue.write { db in
            @discardableResult
            func insertLegacyLink(id: String, url: String) throws -> Int64 {
                try db.execute(
                    sql: """
                    INSERT INTO item (id, contentHash, kind, previewText, searchText, byteSize,
                                      isSecret, createdAt, lastUsedAt, updatedAt)
                    VALUES (?, ?, 'link', ?, ?, ?, 0, '2020-01-01', '2020-01-01', '2020-01-01')
                    """,
                    arguments: [id, "hash-\(id)", url, url, url.utf8.count]
                )
                let rowid = db.lastInsertedRowID
                try db.execute(
                    sql: "INSERT INTO item_fts (rowid, searchText) VALUES (?, ?)",
                    arguments: [rowid, url]
                )
                try db.execute(
                    sql: "INSERT INTO representation (id, itemID, uti, data, byteSize) VALUES (?, ?, ?, ?, ?)",
                    arguments: ["rep-\(id)", id, WellKnownUTI.plainText, Data(url.utf8), url.utf8.count]
                )
                return rowid
            }

            try insertLegacyLink(id: "cred", url: "https://bucket.s3.amazonaws.com/k?X-Amz-Signature=abc123")
            try insertLegacyLink(id: "plain", url: "https://example.com/an-article")

            // Before: the credential link is non-secret and findable.
            #expect(try Int.fetchOne(db, sql: "SELECT isSecret FROM item WHERE id = 'cred'") == 0)
            #expect(try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM item_fts WHERE item_fts MATCH 'amazonaws'"
            ) == 1)

            try Migrations.reclassifyLinkSecrets(db)

            // After: masked, de-indexed, payload retained; ordinary link untouched.
            #expect(try Int.fetchOne(db, sql: "SELECT isSecret FROM item WHERE id = 'cred'") == 1)
            #expect(try String.fetchOne(db, sql: "SELECT searchText FROM item WHERE id = 'cred'") == nil)
            #expect(try String.fetchOne(db, sql: "SELECT previewText FROM item WHERE id = 'cred'")
                == "Secret — Link with credentials")
            #expect(try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM item_fts WHERE item_fts MATCH 'amazonaws'"
            ) == 0)
            // The URL payload survives so paste still works.
            #expect(try Data.fetchOne(db, sql: "SELECT data FROM representation WHERE id = 'rep-cred'") != nil)

            #expect(try Int.fetchOne(db, sql: "SELECT isSecret FROM item WHERE id = 'plain'") == 0)
            #expect(try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM item_fts WHERE item_fts MATCH 'article'"
            ) == 1)
        }
    }
}
