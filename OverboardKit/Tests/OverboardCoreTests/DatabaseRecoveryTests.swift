import Foundation
import GRDB
@testable import OverboardCore
import Testing

struct DatabaseRecoveryTests {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("database-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func migrationBackupIncludesUncheckpointedDataAndPreservesMigrationState() throws {
        let directory = try self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try DatabasePool(path: directory.appendingPathComponent("overboard.sqlite").path)
        try original.write { db in
            try db.execute(sql: "CREATE TABLE recovery_marker (value TEXT)")
            try db.execute(sql: "INSERT INTO recovery_marker VALUES ('before migration')")
        }
        let opened = try OverboardDatabase.openRecoverably(at: directory)
        let backupURL = try #require(opened.migrationBackupURL)
        let backup = try DatabaseQueue(path: backupURL.path)
        let marker = try backup.read { try String.fetchOne($0, sql: "SELECT value FROM recovery_marker") }
        #expect(marker == "before migration")
        #expect(try backup.read { try !Migrations.migrator.hasCompletedMigrations($0) })
        #expect(try opened.database.read { try Migrations.migrator.hasCompletedMigrations($0) })
    }

    @Test func freshAndAlreadyMigratedStoresNeedNoBackup() throws {
        let directory = try self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fresh = try OverboardDatabase.openRecoverably(at: directory)
        #expect(fresh.migrationBackupURL == nil)
        let existing = try OverboardDatabase.openRecoverably(at: directory)
        #expect(existing.migrationBackupURL == nil)
    }

    @Test func failedMigrationReportsRecoveryBackupWithoutDiscardingOriginalData() throws {
        let directory = try self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try DatabasePool(path: directory.appendingPathComponent("overboard.sqlite").path)
        try original.write { db in
            try db.execute(sql: "CREATE TABLE item (marker TEXT)")
            try db.execute(sql: "INSERT INTO item VALUES ('preserved')")
        }
        do {
            _ = try OverboardDatabase.openRecoverably(at: directory)
            Issue.record("Conflicting migration unexpectedly succeeded")
        } catch let error as OverboardDatabase.BootstrapError {
            let backupURL = try #require(error.backupURL)
            #expect(FileManager.default.fileExists(atPath: backupURL.path))
            let backup = try DatabaseQueue(path: backupURL.path)
            let backedUp = try backup.read { try String.fetchOne($0, sql: "SELECT marker FROM item") }
            #expect(backedUp == "preserved")
        }
        let retained = try original.read { try String.fetchOne($0, sql: "SELECT marker FROM item") }
        #expect(retained == "preserved")
    }
}
