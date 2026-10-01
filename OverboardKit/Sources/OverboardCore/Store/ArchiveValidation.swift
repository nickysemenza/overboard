import Foundation

enum ArchiveValidation {
    static func limits(_ limits: ClipArchive.Limits) throws {
        guard limits.archiveBytes > 0, limits.lineBytes > 0, limits.lineBytes < Int.max,
              limits.blobBytes > 0, limits.blobBytes < Int.max, limits.records > 0,
              limits.representations > 0 else { throw ClipArchive.Failure.limit("invalid limits") }
    }

    static func record(_ record: ClipArchive.Record) throws {
        let counters: [Int?] = [
            record.byteSize, record.useCount, record.charCount, record.lineCount,
            record.pixelWidth, record.pixelHeight, record.fileCount,
        ]
        guard !record.id.isEmpty, record.id.utf8.count <= 1024, ArchiveIO.isHash(record.contentHash),
              counters.allSatisfy({ $0.map { (0 ..< Int.max).contains($0) } ?? true }),
              (0 ..< Int64.max).contains(record.lamport ?? 0)
        else {
            throw ClipArchive.Failure.invalid("item metadata")
        }
    }

    static func representation(_ rep: ClipArchive.Rep, limits: ClipArchive.Limits,
                               manifest: ClipArchive.Manifest?) throws
    {
        guard !rep.uti.isEmpty, rep.uti.utf8.count <= 1024, (0 ..< Int.max).contains(rep.byteSize),
              (rep.itemIndex.map { (0 ..< limits.representations).contains($0) } ?? true),
              (rep.data != nil) != (rep.blob != nil) else { throw ClipArchive.Failure.invalid("representation") }
        if let data = rep.data, data.count != rep.byteSize {
            throw ClipArchive.Failure.invalid("inline size")
        }
        if let hash = rep.blob {
            guard ArchiveIO.isHash(hash), rep.byteSize <= limits.blobBytes else {
                throw ClipArchive.Failure.invalid("blob reference")
            }
            if let manifest, manifest.blobs[hash] != rep.byteSize {
                throw ClipArchive.Failure.invalid("unlisted blob reference")
            }
        }
    }

    static func snippet(_ snippet: Snippet) throws {
        guard !snippet.id.isEmpty, snippet.id.utf8.count <= 1024, snippet.deletedAt == nil,
              (0 ..< Int64.max).contains(snippet.lamport) else { throw ClipArchive.Failure.invalid("snippet") }
    }

    static func settings(_ settings: ClipArchive.Settings?) throws {
        guard let settings else { return }
        guard !settings.namespace.isEmpty, (1 ..< Int.max).contains(settings.version) else {
            throw ClipArchive.Failure.invalid("settings version")
        }
        for value in settings.values.values {
            switch value {
            case let .integer(number):
                guard number < Int.max else { throw ClipArchive.Failure.invalid("settings integer") }
            case let .counts(counts):
                guard counts.values.allSatisfy({ (0 ..< Int.max).contains($0) }) else {
                    throw ClipArchive.Failure.invalid("settings counter")
                }
            default: break
            }
        }
    }
}
