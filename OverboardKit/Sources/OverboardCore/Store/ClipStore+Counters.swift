import Foundation
import GRDB

public enum ItemPersistenceCounter: String, Sendable, Equatable {
    case useCount
    case revision
}

public enum ItemPersistenceError: Error, Sendable, Equatable, LocalizedError {
    case counterExhausted(id: String, counter: ItemPersistenceCounter)

    public var errorDescription: String? {
        switch self {
        case let .counterExhausted(_, counter):
            let name = counter == .revision ? "revision" : "usage count"
            return "This item's \(name) cannot advance further. No changes were saved."
        }
    }
}

extension ClipStore {
    static func nextItemCounter(
        after value: Int64, itemID: String, counter: ItemPersistenceCounter
    ) throws -> Int64 {
        guard value < Int64.max else {
            throw ItemPersistenceError.counterExhausted(id: itemID, counter: counter)
        }
        return value + 1
    }

    static func checkItemCountersCanAdvance(
        _ database: Database, itemID: String, includingUseCount: Bool = false
    ) throws {
        guard let row = try Row.fetchOne(
            database, sql: "SELECT lamport, useCount FROM item WHERE id = ?", arguments: [itemID]
        ) else { return }
        _ = try Self.nextItemCounter(after: row["lamport"], itemID: itemID, counter: .revision)
        if includingUseCount {
            _ = try Self.nextItemCounter(after: row["useCount"], itemID: itemID, counter: .useCount)
        }
    }

    static func itemChangeToken(in database: Database) throws -> Int64 {
        let rows = try Row.fetchCursor(database, sql: """
        SELECT 'item' AS entity, id, lamport FROM item
        UNION ALL
        SELECT 'snippet' AS entity, id, lamport FROM snippet
        ORDER BY entity, id
        """)
        var hasher = Hasher()
        while let row = try rows.next() {
            hasher.combine(row["entity"] as String)
            hasher.combine(row["id"] as String)
            hasher.combine(row["lamport"] as Int64)
        }
        return Int64(hasher.finalize())
    }
}
