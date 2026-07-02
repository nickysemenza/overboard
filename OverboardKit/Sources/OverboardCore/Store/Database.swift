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
              isSecret BOOLEAN NOT NULL DEFAULT 0,
              aiTitle TEXT,
              category TEXT,
              aiSummary TEXT,
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
            CREATE INDEX item_secret_expiry
              ON item(createdAt) WHERE isSecret = 1;

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

            CREATE TABLE item_embedding (
              itemID TEXT PRIMARY KEY NOT NULL REFERENCES item(id) ON DELETE CASCADE,
              vector BLOB NOT NULL
            );

            CREATE TABLE snippet (
              id TEXT PRIMARY KEY NOT NULL,
              title TEXT NOT NULL,
              body TEXT NOT NULL,
              createdAt DATETIME NOT NULL,
              updatedAt DATETIME NOT NULL,
              lamport INTEGER NOT NULL DEFAULT 0,
              deletedAt DATETIME
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

        // v2: card metadata footers. Nullable counters backfilled from data
        // already on hand; secrets are skipped so no derived shape leaks.
        migrator.registerMigration("v2") { db in
            for column in ["charCount", "lineCount", "pixelWidth", "pixelHeight", "fileCount"] {
                try db.execute(sql: "ALTER TABLE item ADD COLUMN \(column) INTEGER")
            }

            // text/link: count from the inline plainText payload, not searchText —
            // enrichment appends AI titles/summaries into searchText, so its
            // LENGTH lies for enriched rows. Blob-backed payloads (>32 KB of
            // text) stay NULL rather than store a truncated count.
            let textRows = try Row.fetchAll(db, sql: """
            SELECT item.id AS id, representation.data AS data
            FROM item
            JOIN representation ON representation.itemID = item.id
            WHERE item.isSecret = 0 AND item.kind IN ('text', 'link')
              AND representation.uti = ? AND representation.data IS NOT NULL
            """, arguments: [WellKnownUTI.plainText])
            for row in textRows {
                guard let data = row["data"] as Data?,
                      let text = String(data: data, encoding: .utf8)
                else { continue }
                try db.execute(
                    sql: "UPDATE item SET charCount = ?, lineCount = ? WHERE id = ?",
                    arguments: [text.count, text.lineCount, row["id"] as String]
                )
            }

            // image: recover dimensions from the previewText we already render
            // ("Image W×H"), the sole producer being CaptureClassifier.previewText.
            let imageRows = try Row.fetchAll(db, sql: """
            SELECT id, previewText FROM item
            WHERE isSecret = 0 AND kind = 'image' AND previewText IS NOT NULL
            """)
            for row in imageRows {
                guard let size = ClipItem.imageDimensions(fromPreview: row["previewText"]) else { continue }
                try db.execute(
                    sql: "UPDATE item SET pixelWidth = ?, pixelHeight = ? WHERE id = ?",
                    arguments: [size.width, size.height, row["id"] as String]
                )
            }

            // file: count entries from the inline fileURLs JSON. Blob-backed
            // representations (data IS NULL) stay NULL — the count isn't reachable.
            let fileRows = try Row.fetchAll(db, sql: """
            SELECT item.id AS id, representation.data AS data
            FROM item
            JOIN representation ON representation.itemID = item.id
            WHERE item.isSecret = 0 AND item.kind = 'file'
              AND representation.uti = ? AND representation.data IS NOT NULL
            """, arguments: [WellKnownUTI.fileURLs])
            for row in fileRows {
                guard let data = row["data"] as Data?,
                      let urls = try? JSONDecoder().decode([String].self, from: data)
                else { continue }
                try db.execute(
                    sql: "UPDATE item SET fileCount = ? WHERE id = ?",
                    arguments: [urls.count, row["id"] as String]
                )
            }
        }

        // v3: rich link cards. Columns for a fetched page title/description and
        // pre-downscaled favicon + preview-image PNGs. No in-migration backfill —
        // the data comes from network fetches that run at runtime (post-ingest
        // enrichment + a startup backfill pass over links still missing it).
        migrator.registerMigration("v3") { db in
            try db.execute(sql: "ALTER TABLE item ADD COLUMN linkTitle TEXT")
            try db.execute(sql: "ALTER TABLE item ADD COLUMN linkDescription TEXT")
            try db.execute(sql: "ALTER TABLE item ADD COLUMN faviconData BLOB")
            try db.execute(sql: "ALTER TABLE item ADD COLUMN previewImageData BLOB")
        }

        // v4: back-to-source provenance. When a copy comes from a browser we
        // record that browser's front-tab URL + title, so the clip can link
        // back to where it came from. No backfill — provenance is only knowable
        // at capture time; history predating this can't be reconstructed.
        migrator.registerMigration("v4") { db in
            try db.execute(sql: "ALTER TABLE item ADD COLUMN sourceURL TEXT")
            try db.execute(sql: "ALTER TABLE item ADD COLUMN sourceTitle TEXT")
        }

        return migrator
    }
}
