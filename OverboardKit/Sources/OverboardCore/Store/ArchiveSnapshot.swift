import Foundation
import GRDB

struct ArchiveSnapshot {
    var manifest: ClipArchive.Manifest
    var copiedBlobs: Int
    var missingBlobs: Int
    var secretsExcluded: Int

    static func write(db: Database, blobs: BlobStore, to directory: URL,
                      includeSecrets: Bool, limits: ClipArchive.Limits) throws -> Self
    {
        let items = try ArchiveIO.output(directory.appendingPathComponent(ClipArchive.itemsFileName))
        let snippets = try ArchiveIO.output(directory.appendingPathComponent(ClipArchive.snippetsFileName))
        defer { try? items.close(); try? snippets.close() }
        var builder = ArchiveSnapshotBuilder(
            directory: directory, blobs: blobs, includeSecrets: includeSecrets, limits: limits
        )
        try builder.writeItems(in: db, to: items)
        try builder.writeSnippets(in: db, to: snippets)
        try items.synchronize()
        try snippets.synchronize()
        return try builder.finish()
    }

    static func write(_ data: Data, to url: URL) throws {
        let handle = try ArchiveIO.output(url)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }
}

private struct ArchiveSnapshotBuilder {
    let directory: URL
    let blobs: BlobStore
    let includeSecrets: Bool
    let limits: ClipArchive.Limits
    private let encoder = ClipJSONCoding.archiveEncoder()
    private var blobSizes: [String: Int] = [:]
    private var itemCount = 0
    private var snippetCount = 0
    private var copied = 0
    private var missing = 0
    private var excluded = 0
    private var totalBytes = 0

    init(directory: URL, blobs: BlobStore, includeSecrets: Bool, limits: ClipArchive.Limits) {
        self.directory = directory
        self.blobs = blobs
        self.includeSecrets = includeSecrets
        self.limits = limits
    }

    mutating func writeItems(in database: Database, to output: FileHandle) throws {
        let rows = try Row.fetchCursor(
            database, sql: "SELECT * FROM item WHERE deletedAt IS NULL ORDER BY lastUsedAt DESC, id"
        )
        while let row = try rows.next() {
            try Task.checkCancellation()
            guard let record = try self.record(row, in: database) else { self.excluded += 1; continue }
            self.itemCount += 1
            try self.writeLine(record, to: output, count: self.itemCount)
            try self.copyBlobs(for: record.representations)
        }
    }

    private func record(_ row: Row, in database: Database) throws -> ClipArchive.Record? {
        let item = try ClipItem(row: row)
        let reps = try Representation.fetchAll(
            database,
            sql: "SELECT * FROM representation WHERE itemID = ? ORDER BY itemIndex ASC, rowid ASC",
            arguments: [item.id]
        )
        var record = ClipArchive.Record(item: item, searchText: row["searchText"], representations: reps)
        let sensitive = try item.isSecret || ArchiveSensitivity.label(
            for: record.representations, in: self.blobs.directory, sharded: true, limit: self.limits.blobBytes
        ) != nil || (row["searchText"] as String?).flatMap { ClipSensitivity.label(for: $0) } != nil
        if sensitive, !self.includeSecrets {
            return nil
        }
        record.secret = sensitive
        return record
    }

    private mutating func copyBlobs(for representations: [ClipArchive.Rep]) throws {
        for rep in representations {
            guard let hash = rep.blob else { continue }
            if let known = self.blobSizes[hash] {
                guard known == rep.byteSize else { throw ClipArchive.Failure.invalid("conflicting blob sizes") }
                continue
            }
            self.blobSizes[hash] = rep.byteSize
            if try ArchiveIO.copyBlob(
                "\(hash.prefix(2))/\(hash)", from: self.blobs.directory,
                to: self.directory.appendingPathComponent("blobs/\(hash)"),
                reference: .init(hash: hash, size: rep.byteSize), limit: self.limits.blobBytes
            ) {
                self.copied += 1
                self.totalBytes += rep.byteSize
            } else {
                self.missing += 1
            }
            guard self.totalBytes <= self.limits.archiveBytes else { throw ClipArchive.Failure.limit("total bytes") }
        }
    }

    mutating func writeSnippets(in database: Database, to output: FileHandle) throws {
        let rows = try Snippet.filter(sql: "deletedAt IS NULL").order(Column("id")).fetchCursor(database)
        while let snippet = try rows.next() {
            try Task.checkCancellation()
            if !self.includeSecrets,
               ClipSensitivity.label(for: snippet.body) != nil || ClipSensitivity.label(for: snippet.title) != nil
            {
                self.excluded += 1
                continue
            }
            self.snippetCount += 1
            try self.writeLine(snippet, to: output, count: self.itemCount + self.snippetCount)
        }
    }

    private mutating func writeLine(_ value: some Encodable, to output: FileHandle, count: Int) throws {
        guard count <= self.limits.records else { throw ClipArchive.Failure.limit("record count") }
        var line = try self.encoder.encode(value)
        guard line.count <= self.limits.lineBytes else { throw ClipArchive.Failure.limit("line") }
        line.append(0x0A)
        self.totalBytes += line.count
        guard self.totalBytes <= self.limits.archiveBytes else { throw ClipArchive.Failure.limit("total bytes") }
        try output.write(contentsOf: line)
    }

    func finish() throws -> ArchiveSnapshot {
        let items = try ArchiveIO.lines(ClipArchive.itemsFileName, in: self.directory, limits: self.limits) { _, _ in }
        let snippets = try ArchiveIO
            .lines(ClipArchive.snippetsFileName, in: self.directory, limits: self.limits) { _, _ in }
        return ArchiveSnapshot(
            manifest: .init(
                version: ClipArchive.version, itemCount: self.itemCount, snippetCount: self.snippetCount,
                itemsChecksum: items.checksum, snippetsChecksum: snippets.checksum, blobs: self.blobSizes
            ),
            copiedBlobs: self.copied, missingBlobs: self.missing, secretsExcluded: self.excluded
        )
    }
}
