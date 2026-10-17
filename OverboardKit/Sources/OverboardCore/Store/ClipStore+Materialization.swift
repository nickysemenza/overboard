import Foundation
import GRDB

public struct MaterializedRepresentation: Sendable, Equatable {
    public let representation: Representation
    public let payload: Data

    public init(representation: Representation, payload: Data) {
        self.representation = representation
        self.payload = payload
    }
}

public struct MaterializedClip: Sendable, Equatable {
    public let item: ClipItem
    public let representations: [MaterializedRepresentation]

    public init(item: ClipItem, representations: [MaterializedRepresentation]) {
        self.item = item
        self.representations = representations
    }
}

public extension ClipStore {
    func materialize(itemIDs: [String]) async throws -> [MaterializedClip] {
        let blobs = self.blobs
        // A read, not a write: this only fetches rows and blob files. A purge
        // racing the paste can delete a blob after this snapshot saw its row;
        // that surfaces as a thrown error for an item that was being deleted
        // anyway, which the paste path already handles like "missing".
        return try await self.dbWriter.read { db in
            try itemIDs.map { itemID in
                guard let item = try ClipItem.fetchOne(db, key: itemID), item.deletedAt == nil else {
                    throw DatabaseError(message: "Clip is missing or deleted: \(itemID)")
                }
                let representations = try Representation
                    .filter(sql: "itemID = ?", arguments: [itemID])
                    .order(sql: "itemIndex ASC, rowid ASC")
                    .fetchAll(db)
                guard !representations.isEmpty else {
                    throw DatabaseError(message: "Clip has no representations: \(itemID)")
                }
                let materialized = try representations.map { representation in
                    let payload: Data
                    if let inline = representation.data {
                        payload = inline
                    } else if let hash = representation.blobHash {
                        payload = try blobs.data(for: hash)
                    } else {
                        throw DatabaseError(message: "Representation has no payload: \(representation.id)")
                    }
                    return MaterializedRepresentation(representation: representation, payload: payload)
                }
                return MaterializedClip(item: item, representations: materialized)
            }
        }
    }
}
