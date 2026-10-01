import Foundation

struct PreparedArchive: Sendable {
    let directory: URL
    let settings: ClipArchive.Settings?
    let malformed: [String]
    let missingBlobs: Int

    init(directory source: URL, limits: ClipArchive.Limits) throws {
        try ArchiveValidation.limits(limits)
        guard let items = try ArchiveIO.file(ClipArchive.itemsFileName, in: source, optional: true)
        else { throw ClipArchive.Failure.notAnArchive(source) }
        try items.close()
        let manifestData = try ArchiveIO.smallFile(ClipArchive.manifestFileName, in: source, limit: limits.lineBytes)
        let manifest = try manifestData.map { try ClipJSONCoding.archiveDecoder().decode(
            ClipArchive.Manifest.self,
            from: $0
        ) }
        if let manifest, manifest.version != ClipArchive.version {
            throw ClipArchive.Failure.unsupportedVersion(manifest.version)
        }
        let staged = try ArchiveIO.temporaryDirectory()
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: staged)
            }
        }
        try FileManager.default.createDirectory(
            at: staged.appendingPathComponent("blobs"), withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var preparation = ArchivePreparation(source: source, directory: staged, limits: limits, manifest: manifest)
        preparation.totalBytes = manifestData?.count ?? 0
        let digest = try preparation.prepareItems()
        self.settings = try preparation.prepareMetadata(items: digest)
        guard preparation.totalBytes <= limits.archiveBytes else { throw ClipArchive.Failure.limit("total bytes") }
        self.directory = staged
        self.malformed = preparation.malformed
        self.missingBlobs = preparation.missingBlobs
        completed = true
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.directory)
    }
}

private struct ArchivePreparation {
    let source: URL
    let directory: URL
    let limits: ClipArchive.Limits
    let manifest: ClipArchive.Manifest?
    var totalBytes = 0
    private(set) var malformed: [String] = []
    private(set) var missingBlobs = 0
    private var sizes: [String: Int] = [:]
    private var representationCount = 0
    private let decoder = ClipJSONCoding.archiveDecoder()

    init(source: URL, directory: URL, limits: ClipArchive.Limits, manifest: ClipArchive.Manifest?) {
        self.source = source
        self.directory = directory
        self.limits = limits
        self.manifest = manifest
    }

    mutating func prepareItems() throws -> ArchiveStreamDigest {
        let output = try ArchiveIO.output(self.directory.appendingPathComponent(ClipArchive.itemsFileName))
        defer { try? output.close() }
        let digest = try ArchiveIO
            .lines(ClipArchive.itemsFileName, in: self.source, limits: self.limits) { line, number in
                guard let record = try self.decodeRecord(line, number: number) else { return }
                try ArchiveValidation.record(record)
                try self.prepareRepresentations(record.representations)
                try output.write(contentsOf: line + Data([0x0A]))
            }
        self.totalBytes += digest.bytes
        return digest
    }

    private mutating func decodeRecord(_ line: Data, number: Int) throws -> ClipArchive.Record? {
        let record: ClipArchive.Record
        do {
            record = try self.decoder.decode(ClipArchive.Record.self, from: line)
        } catch {
            if self.manifest != nil {
                throw ClipArchive.Failure.invalid("line \(number)")
            }
            self.malformed.append("line \(number): unreadable record")
            return nil
        }
        guard record.clipItem(id: record.id) != nil else {
            if self.manifest != nil {
                throw ClipArchive.Failure.invalid("item kind")
            }
            self.malformed.append("line \(number): unknown kind")
            return nil
        }
        return record
    }

    private mutating func prepareRepresentations(_ representations: [ClipArchive.Rep]) throws {
        self.representationCount += representations.count
        guard self.representationCount <= self.limits.representations else {
            throw ClipArchive.Failure.limit("representations")
        }
        for rep in representations {
            try ArchiveValidation.representation(rep, limits: self.limits, manifest: self.manifest)
            if let hash = rep.blob {
                try self.prepareBlob(.init(hash: hash, size: rep.byteSize))
            }
        }
    }

    private mutating func prepareBlob(_ reference: ArchiveBlobReference) throws {
        if let size = self.sizes[reference.hash] {
            guard size == reference.size else { throw ClipArchive.Failure.invalid("conflicting blob sizes") }
            return
        }
        self.sizes[reference.hash] = reference.size
        if try ArchiveIO.copyBlob(
            "blobs/\(reference.hash)", from: self.source,
            to: self.directory.appendingPathComponent("blobs/\(reference.hash)"),
            reference: reference, limit: self.limits.blobBytes
        ) {
            self.totalBytes += reference.size
        } else {
            self.missingBlobs += 1
        }
        guard self.totalBytes <= self.limits.archiveBytes else { throw ClipArchive.Failure.limit("total bytes") }
    }

    mutating func prepareMetadata(items: ArchiveStreamDigest) throws -> ClipArchive.Settings? {
        let output = try ArchiveIO.output(self.directory.appendingPathComponent(ClipArchive.snippetsFileName))
        defer { try? output.close() }
        guard let manifest = self.manifest else { return nil }
        guard manifest.itemCount == items.count, manifest.itemsChecksum == items.checksum,
              Set(manifest.blobs.keys) == Set(self.sizes.keys)
        else {
            throw ClipArchive.Failure.checksum(ClipArchive.itemsFileName)
        }
        try self.prepareSnippets(manifest, items: items, output: output)
        return try self.prepareSettings(manifest)
    }

    private mutating func prepareSnippets(_ manifest: ClipArchive.Manifest, items: ArchiveStreamDigest,
                                          output: FileHandle) throws
    {
        let digest = try ArchiveIO
            .lines(ClipArchive.snippetsFileName, in: self.source, limits: self.limits) { line, _ in
                try ArchiveValidation.snippet(self.decoder.decode(Snippet.self, from: line))
                try output.write(contentsOf: line + Data([0x0A]))
            }
        guard items.count + digest.count <= self.limits.records else { throw ClipArchive.Failure.limit("record count") }
        self.totalBytes += digest.bytes
        guard digest.checksum == manifest.snippetsChecksum, digest.count == manifest.snippetCount else {
            throw ClipArchive.Failure.checksum(ClipArchive.snippetsFileName)
        }
    }

    private mutating func prepareSettings(_ manifest: ClipArchive.Manifest) throws -> ClipArchive.Settings? {
        let data = try ArchiveIO.smallFile(ClipArchive.settingsFileName, in: self.source, limit: self.limits.lineBytes)
        guard data.map(BlobStore.hash) == manifest.settingsChecksum else {
            throw ClipArchive.Failure.checksum(ClipArchive.settingsFileName)
        }
        self.totalBytes += data?.count ?? 0
        let settings = try data.map { try self.decoder.decode(ClipArchive.Settings.self, from: $0) }
        try ArchiveValidation.settings(settings)
        return settings
    }
}
