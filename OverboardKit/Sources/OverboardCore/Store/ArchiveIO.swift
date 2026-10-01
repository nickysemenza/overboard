import CryptoKit
import Darwin
import Foundation

struct ArchiveStreamDigest {
    let checksum: String
    let bytes: Int
    let count: Int
}

struct ArchiveBlobReference {
    let hash: String
    let size: Int
}

enum ArchiveIO {
    static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    static func directory(_ url: URL) throws -> Int32 {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ClipArchive.Failure.unsafePath(url.lastPathComponent) }
        return descriptor
    }

    static func file(_ name: String, in root: URL, optional: Bool = false) throws -> FileHandle? {
        let parts = name.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !name.hasPrefix("/"), parts.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw ClipArchive.Failure.unsafePath(name)
        }
        var parent = try directory(root)
        defer { Darwin.close(parent) }
        for component in parts.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, optional, errno == ENOENT {
                return nil
            }
            guard next >= 0 else { throw ClipArchive.Failure.unsafePath(name) }
            Darwin.close(parent)
            parent = next
        }
        let descriptor = openat(parent, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0, optional, errno == ENOENT {
            return nil
        }
        guard descriptor >= 0 else { throw ClipArchive.Failure.unsafePath(name) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw ClipArchive.Failure.unsafePath(name)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func output(_ url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func smallFile(_ name: String, in root: URL, limit: Int) throws -> Data? {
        guard let handle = try file(name, in: root, optional: true) else { return nil }
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw ClipArchive.Failure.limit(name) }
        return bytes
    }

    static func lines(
        _ name: String, in root: URL, limits: ClipArchive.Limits,
        consume: (Data, Int) throws -> Void
    ) throws -> ArchiveStreamDigest {
        try Task.checkCancellation()
        guard let handle = try file(name, in: root) else { throw ClipArchive.Failure.notAnArchive(root) }
        defer { try? handle.close() }
        var pending = Data()
        var digest = SHA256()
        var bytes = 0
        var lineNumber = 0
        var count = 0
        func emit(_ line: Data) throws {
            try Task.checkCancellation()
            lineNumber += 1
            guard line.count <= limits.lineBytes else { throw ClipArchive.Failure.limit("line \(lineNumber)") }
            if line.isEmpty {
                return
            }
            count += 1
            guard count <= limits.records else { throw ClipArchive.Failure.limit("record count") }
            try consume(line, lineNumber)
        }
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            bytes += chunk.count
            guard bytes <= limits.archiveBytes else { throw ClipArchive.Failure.limit(name) }
            digest.update(data: chunk)
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                try emit(Data(pending[..<newline]))
                pending = Data(pending[pending.index(after: newline)...])
            }
            guard pending.count <= limits.lineBytes else { throw ClipArchive.Failure.limit("line \(lineNumber + 1)") }
        }
        if !pending.isEmpty {
            try emit(pending)
        }
        return ArchiveStreamDigest(checksum: self.hex(digest.finalize()), bytes: bytes, count: count)
    }

    static func copyBlob(_ name: String, from root: URL, to destination: URL,
                         reference: ArchiveBlobReference, limit: Int) throws -> Bool
    {
        let hash = reference.hash
        let size = reference.size
        guard self.isHash(hash), size >= 0, size <= limit else { throw ClipArchive.Failure.invalid("blob reference") }
        guard let source = try file(name, in: root, optional: true) else { return false }
        defer { try? source.close() }
        let target = try output(destination)
        defer { try? target.close() }
        var digest = SHA256()
        var bytes = 0
        while let chunk = try source.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            bytes += chunk.count
            guard bytes <= size, bytes <= limit else { throw ClipArchive.Failure.invalid("blob size \(hash)") }
            digest.update(data: chunk)
            try target.write(contentsOf: chunk)
        }
        guard bytes == size, self.hex(digest.finalize()) == hash else { throw ClipArchive.Failure.checksum(hash) }
        try target.synchronize()
        return true
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func validBlob(_ hash: String, size: Int, in root: URL) throws -> Bool {
        guard self.isHash(hash) else { throw ClipArchive.Failure.invalid("blob hash") }
        guard let handle = try file("\(hash.prefix(2))/\(hash)", in: root, optional: true) else { return false }
        defer { try? handle.close() }
        var digest = SHA256()
        var bytes = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            bytes += chunk.count
            if bytes > size {
                return false
            }
            digest.update(data: chunk)
        }
        return bytes == size && self.hex(digest.finalize()) == hash
    }

    static func installBlob(_ hash: String, from source: URL, in root: URL) throws {
        guard self.isHash(hash),
              let input = try file("blobs/\(hash)", in: source) else { throw ClipArchive.Failure.invalid("blob hash") }
        defer { try? input.close() }
        let parent = try directory(root)
        defer { Darwin.close(parent) }
        let shardName = String(hash.prefix(2))
        if mkdirat(parent, shardName, 0o700) != 0, errno != EEXIST {
            throw CocoaError(.fileWriteUnknown)
        }
        let shard = openat(parent, shardName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard shard >= 0 else { throw ClipArchive.Failure.unsafePath(shardName) }
        defer { Darwin.close(shard) }
        var info = stat()
        if fstatat(shard, hash, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT != S_IFREG {
            throw ClipArchive.Failure.unsafePath(hash)
        }
        let name = ".archive-\(UUID().uuidString)"
        let descriptor = openat(shard, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close(); _ = unlinkat(shard, name, 0) }
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
        guard renameat(shard, name, shard, hash) == 0 else { throw CocoaError(.fileWriteUnknown) }
        _ = fsync(shard)
    }

    static func temporaryDirectory(beside destination: URL? = nil) throws -> URL {
        let parent = destination?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
        let descriptor = try directory(parent)
        defer { Darwin.close(descriptor) }
        let name = ".overboard-archive-\(UUID().uuidString)"
        guard mkdirat(descriptor, name, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
        return parent.appendingPathComponent(name, isDirectory: true)
    }

    static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = try directory(url)
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    static func publish(_ staged: URL, to destination: URL) throws {
        let parent = try directory(destination.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        var info = stat()
        let exists = fstatat(parent, destination.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0
        if exists {
            guard info.st_mode & S_IFMT == S_IFDIR,
                  try self.file(ClipArchive.itemsFileName, in: destination, optional: true) != nil
            else {
                throw ClipArchive.Failure.unsafePath(destination.lastPathComponent)
            }
            try Task.checkCancellation()
            guard renameatx_np(
                parent,
                staged.lastPathComponent,
                parent,
                destination.lastPathComponent,
                UInt32(RENAME_SWAP)
            ) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        } else {
            try Task.checkCancellation()
            guard errno == ENOENT,
                  renameatx_np(
                      parent,
                      staged.lastPathComponent,
                      parent,
                      destination.lastPathComponent,
                      UInt32(RENAME_EXCL)
                  ) == 0
            else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        _ = fsync(parent)
    }
}
