import Darwin
import Foundation
import os
import OverboardCore
import UniformTypeIdentifiers

/// One directory entry as reported by `getattrlistbulk(2)`.
///
/// Everything the scanner needs arrives in the same kernel call that lists the
/// directory. Foundation's `resourceValues(forKeys:)` instead makes one
/// FileProvider round trip per item on iCloud Drive and similar domains.
nonisolated struct BulkEntry: Sendable {
    enum Kind: Sendable {
        case directory, regular, symlink, other
    }

    /// Name exactly as the filesystem spelled it. May be decomposed (NFD).
    let name: String
    let kind: Kind
    let modifiedAt: Date
    /// `st_flags`-style BSD flags (`ATTR_CMN_FLAGS`).
    let flags: UInt32
    /// Big-endian `frFlags` of the Finder info; 0 when not returned.
    let finderFlags: UInt16

    var isDirectory: Bool {
        self.kind == .directory
    }

    var isSymbolicLink: Bool {
        self.kind == .symlink
    }

    /// A cloud placeholder whose content is not on disk. Equivalent to the
    /// `lstat` check `FileAvailability.status(at:)` performs, without a
    /// second syscall per entry.
    var isDataless: Bool {
        self.flags & UInt32(SF_DATALESS) != 0
    }

    var hasBundleBit: Bool {
        self.finderFlags & BulkDirectoryWalker.hasBundleFinderFlag != 0
    }

    var availability: FileSearchInfo.Availability {
        self.isDataless ? .cloud : .local
    }
}

/// A failed open or read of a directory, carrying the errno text.
nonisolated struct BulkDirectoryError: Error, Sendable {
    let code: Int32

    var message: String {
        String(cString: strerror(self.code))
    }
}

/// Entries read from one directory plus the error that cut the read short.
/// Entries delivered before a mid-read error are still valid, matching how
/// the `FileManager` enumerator kept going after reporting a failure.
nonisolated struct BulkListing: Sendable {
    var entries: [BulkEntry] = []
    var error: BulkDirectoryError?
}

/// Decides whether a directory is a package (an opaque "file" such as `.app`)
/// without asking LaunchServices or a FileProvider per item, which is what
/// `URLResourceKey.isPackageKey` does.
///
/// A directory is a package when either (a) its path extension maps to a
/// `UTType` conforming to `.package`, or (b) its Finder info has the
/// `kHasBundle` bit set. The extension answer is cached per lowercased
/// extension for the life of the process, so the type database is asked about
/// each distinct extension once; the FSEvents filter shares the cache.
final nonisolated class PackageClassifier {
    private static let byExtension = OSAllocatedUnfairLock(initialState: [String: Bool]())

    func isPackage(name: String, finderFlags: UInt16) -> Bool {
        finderFlags & BulkDirectoryWalker.hasBundleFinderFlag != 0 || Self.hasPackageExtension(name)
    }

    /// The extension half of the rule alone, for callers with only a name.
    static func hasPackageExtension(_ name: some StringProtocol) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...].lowercased()
        guard !ext.isEmpty else { return false }
        if let cached = self.byExtension.withLock({ $0[ext] }) {
            return cached
        }
        // Plain `UTType(filenameExtension:)` prefers the file flavor (`.app`
        // is `application-file`); asking for a package-conforming type finds
        // the bundle flavor. Unknown extensions yield a dynamic type that
        // claims conformance to anything asked, so those must be rejected.
        let type = UTType(filenameExtension: ext, conformingTo: .package)
        let answer = type.map { !$0.isDynamic && $0.conforms(to: .package) } ?? false
        self.byExtension.withLock { $0[ext] = answer }
        return answer
    }
}

/// Reads directories with `getattrlistbulk(2)`: names, object types,
/// modification times, BSD flags and Finder info for many entries per syscall,
/// with no per-item URL or FileProvider work.
///
/// Owns one reusable buffer, so an instance must not be shared across
/// concurrent tasks. Symlinks are reported, never followed.
final nonisolated class BulkDirectoryWalker {
    /// `kHasBundle` in the Finder flags: the folder is treated as a bundle.
    static let hasBundleFinderFlag: UInt16 = 0x2000

    private static let bufferSize = 256 * 1024
    private static let requestedCommon =
        attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME)
            | attrgroup_t(ATTR_CMN_FNDRINFO) | attrgroup_t(ATTR_CMN_FLAGS)

    private let buffer: UnsafeMutableRawPointer

    init() {
        self.buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 8)
    }

    deinit {
        self.buffer.deallocate()
    }

    private static func attributeList() -> attrlist {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = self.requestedCommon
        return list
    }

    /// Lists every non-dot entry of `path`. Never throws: failures land in
    /// `BulkListing.error` next to whatever was read before them.
    func list(path: String) -> BulkListing {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return BulkListing(error: BulkDirectoryError(code: errno)) }
        defer { close(descriptor) }
        var listing = BulkListing()
        var request = Self.attributeList()
        while true {
            let count = getattrlistbulk(descriptor, &request, self.buffer, Self.bufferSize, 0)
            if count < 0 {
                listing.error = BulkDirectoryError(code: errno)
                break
            }
            if count == 0 {
                break
            }
            var cursor = UnsafeRawPointer(self.buffer)
            for _ in 0 ..< count {
                let length = Int(cursor.loadUnaligned(as: UInt32.self))
                if let entry = Self.parse(cursor, length: length) {
                    listing.entries.append(entry)
                }
                cursor += length
            }
        }
        return listing
    }

    /// Metadata for one path without following a final symlink, parsed by the
    /// same code as directory listings so both agree on every field.
    static func stat(path: String) throws(BulkDirectoryError) -> BulkEntry {
        var request = self.attributeList()
        let size = 4096
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { scratch.deallocate() }
        guard getattrlist(path, &request, scratch, size, UInt32(FSOPT_NOFOLLOW)) == 0 else {
            throw BulkDirectoryError(code: errno)
        }
        let length = Int(scratch.loadUnaligned(as: UInt32.self))
        guard let entry = self.parse(UnsafeRawPointer(scratch), length: length) else {
            throw BulkDirectoryError(code: EIO)
        }
        return entry
    }

    /// Decodes one packed record: `u32 length`, `attribute_set_t` of what was
    /// actually returned, then each returned field in ascending attribute-bit
    /// order. The kernel packs fields on 4-byte boundaries, so wider values
    /// (the 16-byte timespec) are read unaligned. Absent fields are skipped
    /// rather than assumed.
    private static func parse(_ record: UnsafeRawPointer, length: Int) -> BulkEntry? {
        var offset = 4
        let returned = record.loadUnaligned(fromByteOffset: offset, as: attribute_set_t.self)
        offset += MemoryLayout<attribute_set_t>.size
        let common = returned.commonattr

        var name: String?
        if common & attrgroup_t(ATTR_CMN_NAME) != 0 {
            let reference = record.loadUnaligned(fromByteOffset: offset, as: attrreference_t.self)
            // The offset is relative to the attrreference_t itself.
            let start = record + offset + Int(reference.attr_dataoffset)
            name = String(cString: start.assumingMemoryBound(to: CChar.self))
            offset += MemoryLayout<attrreference_t>.size
        }
        var kind = BulkEntry.Kind.other
        if common & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            let type = record.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            kind = switch type {
            case UInt32(VDIR.rawValue): .directory
            case UInt32(VREG.rawValue): .regular
            case UInt32(VLNK.rawValue): .symlink
            default: .other
            }
            offset += 4
        }
        var modifiedAt = Date.distantPast
        if common & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
            modifiedAt = self.date(record.loadUnaligned(fromByteOffset: offset, as: timespec.self))
            offset += MemoryLayout<timespec>.size
        }
        var finderFlags: UInt16 = 0
        if common & attrgroup_t(ATTR_CMN_FNDRINFO) != 0 {
            // frFlags sits at byte 8 of the 32-byte Finder info, big-endian.
            finderFlags = UInt16(bigEndian: record.loadUnaligned(fromByteOffset: offset + 8, as: UInt16.self))
            offset += 32
        }
        var flags: UInt32 = 0
        if common & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
            flags = record.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
        guard let name, offset <= length else { return nil }
        return BulkEntry(name: name, kind: kind, modifiedAt: modifiedAt, flags: flags, finderFlags: finderFlags)
    }

    private static func date(_ value: timespec) -> Date {
        Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000)
    }
}
