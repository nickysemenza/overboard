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

    /// Monotonic change fingerprint over `item` and `snippet`, read from the
    /// trigger-maintained `change_counter` row (migration v8): one primary-key
    /// lookup regardless of library size. Any insert, update, or delete on
    /// either table advances it.
    static func itemChangeToken(in database: Database) throws -> Int64 {
        try Int64.fetchOne(database, sql: "SELECT revision FROM change_counter WHERE id = 1") ?? 0
    }
}
