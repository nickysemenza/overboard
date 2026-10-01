import Foundation
import GRDB
@testable import OverboardCore
import Testing

struct MigrationRecoveryTests {
    @Test func populatedMigrationCreatesRecoverableSnapshotAndRetainsValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try DatabaseQueue(path: directory.appendingPathComponent("overboard.sqlite").path)
        try Migrations.migrator.migrate(source, upTo: "v1")
        let payload = Data("Preserved payload".utf8)
        try source.write { database in
            try database.execute(sql: """
            INSERT INTO item
              (id, contentHash, kind, previewText, byteSize, isPinned, createdAt, lastUsedAt, updatedAt)
            VALUES ('stable-id', 'stable-hash', 'text', 'Preserved payload', ?, 1, ?, ?, ?)
            """, arguments: [payload.count, Date(), Date(), Date()])
            try database.execute(sql: """
            INSERT INTO representation (id, itemID, uti, data, byteSize)
            VALUES ('stable-representation', 'stable-id', ?, ?, ?)
            """, arguments: [WellKnownUTI.plainText, payload, payload.count])
            try database.execute(sql: """
            INSERT INTO snippet (id, title, body, createdAt, updatedAt, lamport)
            VALUES ('stable-snippet', 'Greeting', 'Hello {clipboard}', ?, ?, 12)
            """, arguments: [Date(), Date()])
            try database.execute(sql: "INSERT INTO meta (key, value) VALUES ('configuration', 'preserved')")
        }
        let migrated = try OverboardDatabase.open(at: directory)
        try migrated.read { database in
            let itemID = try String.fetchOne(database, sql: "SELECT id FROM item")
            let pinned = try Bool.fetchOne(database, sql: "SELECT isPinned FROM item")
            let representation = try Data.fetchOne(database, sql: "SELECT data FROM representation")
            let revision = try Int.fetchOne(database, sql: "SELECT lamport FROM snippet")
            let configuration = try String.fetchOne(database, sql: "SELECT value FROM meta WHERE key = 'configuration'")
            #expect(itemID == "stable-id")
            #expect(pinned == true)
            #expect(representation == payload)
            #expect(revision == 12)
            #expect(configuration == "preserved")
        }
        let backupDirectory = directory.appendingPathComponent("MigrationBackups")
        let backups = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        let backup = try DatabaseQueue(path: #require(backups.first).path)
        try backup.read { database in
            let itemID = try String.fetchOne(database, sql: "SELECT id FROM item")
            let representation = try Data.fetchOne(database, sql: "SELECT data FROM representation")
            let migrations = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM grdb_migrations")
            #expect(itemID == "stable-id")
            #expect(representation == payload)
            #expect(migrations == 1)
        }
        _ = try OverboardDatabase.open(at: directory)
        let backupNames = try FileManager.default.contentsOfDirectory(atPath: backupDirectory.path)
        #expect(backupNames.filter { $0.hasSuffix(".sqlite") }.count == 1)
    }

    @Test func corruptDatabaseFailsWithoutReplacingOriginalBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("overboard.sqlite")
        let bytes = Data("recoverable original bytes, not a database".utf8)
        try bytes.write(to: sourceURL)
        #expect(throws: (any Error).self) { try OverboardDatabase.open(at: directory) }
        #expect(try Data(contentsOf: sourceURL) == bytes)
    }
}
