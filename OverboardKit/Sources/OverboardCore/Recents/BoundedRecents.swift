import OrderedCollections

/// Unique values ordered from most to least recently used. Persistence stays
/// outside this type so each caller can retain its established wire format.
public struct BoundedRecents<Element: Hashable> {
    private var storage: OrderedSet<Element>
    public let limit: Int

    public init(mostRecentFirst values: some Sequence<Element>, limit: Int) {
        precondition(limit >= 0, "A recent-items limit cannot be negative")
        self.limit = limit
        self.storage = OrderedSet(values)
        if self.storage.count > limit {
            self.storage.removeLast(self.storage.count - limit)
        }
    }

    public var mostRecentFirst: [Element] {
        Array(self.storage)
    }

    public mutating func record(_ value: Element) {
        self.storage.remove(value)
        guard self.limit > 0 else { return }
        self.storage.insert(value, at: 0)
        if self.storage.count > self.limit {
            self.storage.removeLast()
        }
    }

    public mutating func remove(_ value: Element) {
        self.storage.remove(value)
    }

    public mutating func prune(keeping isIncluded: (Element) throws -> Bool) rethrows {
        self.storage = try OrderedSet(self.storage.filter(isIncluded))
    }
}
