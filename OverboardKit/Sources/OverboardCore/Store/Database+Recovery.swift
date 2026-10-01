import Foundation
import GRDB

public extension OverboardDatabase {
    struct BootstrapResult: Sendable {
        public let database: DatabasePool
        public let migrationBackupURL: URL?
    }

    enum BootstrapError: Error, Sendable, LocalizedError {
        case migrationFailed(backupURL: URL?, message: String)

        public var backupURL: URL? {
            switch self {
            case let .migrationFailed(backupURL, _): backupURL
            }
        }

        public var errorDescription: String? {
            switch self {
            case let .migrationFailed(backupURL, message):
                if let backupURL {
                    "Database migration failed: \(message). Recovery backup: \(backupURL.path)."
                } else {
                    "Database migration failed: \(message)."
                }
            }
        }
    }

    static func openRecoverably(at directory: URL) throws -> BootstrapResult {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let databaseURL = directory.appendingPathComponent("overboard.sqlite")
        let existing = fileManager.fileExists(atPath: databaseURL.path)
        let pool = try DatabasePool(path: databaseURL.path)
        let migrator = Migrations.migrator
        let needsMigration = try pool.read { try !migrator.hasCompletedMigrations($0) }
        var backupURL: URL?
        if existing, needsMigration {
            let backups = directory.appendingPathComponent("MigrationBackups", isDirectory: true)
            try fileManager.createDirectory(
                at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            let destination = backups.appendingPathComponent("pre-migration-\(UUID().uuidString).sqlite")
            let backup = try DatabaseQueue(path: destination.path)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            try pool.backup(to: backup)
            backupURL = destination
        }
        do {
            try migrator.migrate(pool)
        } catch {
            throw BootstrapError.migrationFailed(backupURL: backupURL, message: error.localizedDescription)
        }
        return BootstrapResult(database: pool, migrationBackupURL: backupURL)
    }
}
