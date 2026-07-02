import CryptoKit
import Foundation

/// Content-addressed file storage for large representation payloads.
/// Files live at `<directory>/ab/<sha256-hex>` keyed by the SHA-256 of their
/// contents, which makes identical payloads dedupe for free.
public struct BlobStore: Sendable {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// Stores the data (no-op if an identical blob already exists) and returns its hash.
    @discardableResult
    public func store(_ data: Data) throws -> String {
        let hash = Self.hash(data)
        let url = url(for: hash)
        guard !FileManager.default.fileExists(atPath: url.path) else { return hash }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: .atomic)
        return hash
    }

    public func data(for hash: String) throws -> Data {
        try Data(contentsOf: self.url(for: hash))
    }

    public func delete(hash: String) throws {
        let url = url(for: hash)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func url(for hash: String) -> URL {
        self.directory
            .appendingPathComponent(String(hash.prefix(2)), isDirectory: true)
            .appendingPathComponent(hash)
    }

    public func exists(hash: String) -> Bool {
        FileManager.default.fileExists(atPath: self.url(for: hash).path)
    }

    /// Every blob hash currently on disk (filenames under the `ab/` shards).
    /// Used by the maintenance sweep to find files no representation references.
    public func allHashes() -> Set<String> {
        let fm = FileManager.default
        guard let shards = try? fm.contentsOfDirectory(
            at: self.directory, includingPropertiesForKeys: nil
        ) else { return [] }
        var hashes: Set<String> = []
        for shard in shards where (try? shard.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            guard let files = try? fm.contentsOfDirectory(at: shard, includingPropertiesForKeys: nil)
            else { continue }
            for file in files {
                hashes.insert(file.lastPathComponent)
            }
        }
        return hashes
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
