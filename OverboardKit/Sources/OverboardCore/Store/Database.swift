import Foundation
import GRDB

/// All database bootstrap lives here so storage decisions (e.g. adding
/// encryption later) touch exactly one file.
public enum OverboardDatabase {
    /// `~/Library/Application Support/Overboard`, created `0o700`.
    public static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("Overboard", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }

    public static func open(at directory: URL) throws -> DatabasePool {
        let pool = try DatabasePool(path: directory.appendingPathComponent("overboard.sqlite").path)
        try Migrations.migrator.migrate(pool)
        return pool
    }

    /// In-memory database for tests.
    public static func openInMemory() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue)
        return queue
    }
}

enum Migrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE item (
              id TEXT PRIMARY KEY NOT NULL,
              contentHash TEXT NOT NULL,
              kind TEXT NOT NULL,
              previewText TEXT,
              searchText TEXT,
              sourceBundleID TEXT,
              sourceAppName TEXT,
              byteSize INTEGER NOT NULL,
              isPinned BOOLEAN NOT NULL DEFAULT 0,
              useCount INTEGER NOT NULL DEFAULT 1,
              createdAt DATETIME NOT NULL,
              lastUsedAt DATETIME NOT NULL,
              updatedAt DATETIME NOT NULL,
              lamport INTEGER NOT NULL DEFAULT 0,
              deletedAt DATETIME
            );

            CREATE UNIQUE INDEX item_contentHash_live
              ON item(contentHash) WHERE deletedAt IS NULL;
            CREATE INDEX item_lastUsedAt ON item(lastUsedAt DESC);

            CREATE TABLE representation (
              id TEXT PRIMARY KEY NOT NULL,
              itemID TEXT NOT NULL REFERENCES item(id) ON DELETE CASCADE,
              uti TEXT NOT NULL,
              data BLOB,
              blobHash TEXT,
              byteSize INTEGER NOT NULL
            );

            CREATE INDEX representation_itemID ON representation(itemID);
            CREATE INDEX representation_blobHash ON representation(blobHash);

            CREATE VIRTUAL TABLE item_fts USING fts5(
              searchText,
              content='item',
              content_rowid='rowid',
              prefix='2 3',
              tokenize='unicode61 remove_diacritics 2'
            );

            CREATE TABLE meta (
              key TEXT PRIMARY KEY NOT NULL,
              value TEXT NOT NULL
            );
            """)
            try db.execute(
                sql: "INSERT INTO meta (key, value) VALUES ('deviceID', ?)",
                arguments: [UUID().uuidString]
            )
        }

        migrator.registerMigration("v2-snippets") { db in
            try db.execute(sql: """
            CREATE TABLE snippet (
              id TEXT PRIMARY KEY NOT NULL,
              title TEXT NOT NULL,
              body TEXT NOT NULL,
              createdAt DATETIME NOT NULL,
              updatedAt DATETIME NOT NULL,
              lamport INTEGER NOT NULL DEFAULT 0,
              deletedAt DATETIME
            );
            """)
        }

        migrator.registerMigration("v3-secrets-embeddings") { db in
            try db.execute(sql: """
            ALTER TABLE item ADD COLUMN isSecret BOOLEAN NOT NULL DEFAULT 0;

            CREATE INDEX item_secret_expiry
              ON item(createdAt) WHERE isSecret = 1;

            CREATE TABLE item_embedding (
              itemID TEXT PRIMARY KEY NOT NULL REFERENCES item(id) ON DELETE CASCADE,
              vector BLOB NOT NULL
            );
            """)
        }

        migrator.registerMigration("v4-ai-enrichment") { db in
            try db.execute(sql: """
            ALTER TABLE item ADD COLUMN aiTitle TEXT;
            ALTER TABLE item ADD COLUMN category TEXT;
            """)
        }

        migrator.registerMigration("v5-ai-summary") { db in
            try db.execute(sql: "ALTER TABLE item ADD COLUMN aiSummary TEXT;")
        }

        return migrator
    }
}
