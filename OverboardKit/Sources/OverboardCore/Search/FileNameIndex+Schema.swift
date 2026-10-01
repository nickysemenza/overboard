import Foundation
import GRDB

extension FileNameIndex {
    static func makeDatabase(url: URL?) throws -> any DatabaseWriter {
        var configuration = Configuration()
        configuration.maximumReaderCount = 4
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
        }
        if let url {
            return try DatabasePool(path: url.path, configuration: configuration)
        }
        return try DatabaseQueue(configuration: configuration)
    }

    static func createSchema(in database: any DatabaseWriter) throws {
        try database.write { db in
            try Self.createTables(in: db)
            try Self.updateTrigger(in: db)
        }
    }

    private static func createTables(in db: Database) throws {
        if try !db.tableExists("file_entry") {
            try db.execute(sql: "PRAGMA user_version = \(maintenanceVersion)")
        }
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS file_entry (
            path TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL,
            foldedName TEXT NOT NULL, foldedPath TEXT NOT NULL,
            root TEXT NOT NULL, generation TEXT NOT NULL,
            modifiedAt DATETIME NOT NULL, availability TEXT NOT NULL,
            isDirectory BOOLEAN NOT NULL, location TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS file_root ON file_entry(root, generation);
        CREATE INDEX IF NOT EXISTS file_recent ON file_entry(modifiedAt DESC);
        CREATE INDEX IF NOT EXISTS file_name ON file_entry(foldedName);
        CREATE VIRTUAL TABLE IF NOT EXISTS file_fts USING fts5(
            foldedName, foldedPath, content='file_entry', content_rowid='rowid', tokenize='trigram'
        );
        CREATE TRIGGER IF NOT EXISTS file_insert AFTER INSERT ON file_entry BEGIN
            INSERT INTO file_fts(rowid, foldedName, foldedPath) VALUES (new.rowid, new.foldedName, new.foldedPath);
        END;
        CREATE TRIGGER IF NOT EXISTS file_delete AFTER DELETE ON file_entry BEGIN
            INSERT INTO file_fts(file_fts, rowid, foldedName, foldedPath) VALUES \
        ('delete', old.rowid, old.foldedName, old.foldedPath);
        END;
        CREATE TEMP TABLE IF NOT EXISTS file_scan_seen (
            scanID TEXT NOT NULL, path TEXT NOT NULL,
            PRIMARY KEY (scanID, path)
        ) WITHOUT ROWID;
        """)
    }

    private static func updateTrigger(in db: Database) throws {
        let updateTrigger = try String.fetchOne(
            db,
            sql: "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = 'file_update'"
        )
        if updateTrigger?.contains("AFTER UPDATE OF foldedName, foldedPath") != true {
            try db.execute(sql: "DROP TRIGGER IF EXISTS file_update")
            try db.execute(sql: """
            CREATE TRIGGER file_update AFTER UPDATE OF foldedName, foldedPath ON file_entry
            WHEN old.foldedName IS NOT new.foldedName OR old.foldedPath IS NOT new.foldedPath BEGIN
                INSERT INTO file_fts(file_fts, rowid, foldedName, foldedPath) VALUES \
            ('delete', old.rowid, old.foldedName, old.foldedPath);
                INSERT INTO file_fts(rowid, foldedName, foldedPath) VALUES \
            (new.rowid, new.foldedName, new.foldedPath);
            END;
            """)
        }
    }
}
