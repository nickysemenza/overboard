import Observation
import OverboardCore

/// A FIFO queue of items to paste sequentially. Queue from the drawer with
/// ⌘↩, then pop with the paste-next global hotkey (default ⌥⌘V).
/// Session-scoped by design — not persisted.
@MainActor
@Observable
public final class PasteStack {
    public private(set) var items: [ClipItem] = []

    public init() {}

    public var count: Int {
        self.items.count
    }

    public func push(_ item: ClipItem) {
        self.items.append(item)
    }

    public func popNext() -> ClipItem? {
        self.items.isEmpty ? nil : self.items.removeFirst()
    }

    public func clear() {
        self.items.removeAll()
    }
}
