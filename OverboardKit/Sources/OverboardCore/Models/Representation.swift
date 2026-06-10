import Foundation
import GRDB

/// One pasteboard representation of an item (e.g. the RTF flavor of a text clip).
/// Payloads under `inlineThreshold` live in the database; larger ones live in
/// the `BlobStore`, referenced by content hash.
public struct Representation: Codable, Sendable, Equatable, Identifiable {
    /// Payloads at or above this size are stored in the BlobStore instead of inline.
    public static let inlineThreshold = 32 * 1024

    public var id: String
    public var itemID: String
    public var uti: String
    public var data: Data?
    public var blobHash: String?
    public var byteSize: Int

    public init(
        id: String = UUID().uuidString,
        itemID: String,
        uti: String,
        data: Data?,
        blobHash: String?,
        byteSize: Int
    ) {
        self.id = id
        self.itemID = itemID
        self.uti = uti
        self.data = data
        self.blobHash = blobHash
        self.byteSize = byteSize
    }
}

extension Representation: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "representation"
}
