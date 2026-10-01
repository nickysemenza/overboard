import Foundation
import Observation
import OverboardCore

/// A FIFO queue of items to paste sequentially. Queue from the drawer with
/// ⌘↩, then pop with the paste-next global hotkey (default ⌥⌘V).
/// Session-scoped by design — not persisted.
@Observable
public final class PasteStack {
    public struct Reservation: Sendable {
        public let id: UUID
        public let item: ClipItem
    }

    public private(set) var items: [ClipItem] = []
    private var reservation: Reservation?

    public init() {}

    public var count: Int {
        self.items.count
    }

    public func push(_ item: ClipItem) {
        self.items.append(item)
    }

    public func popNext() -> ClipItem? {
        guard let reservation = self.reserveNext(), self.commit(reservation) else { return nil }
        return reservation.item
    }

    public func reserveNext() -> Reservation? {
        guard self.reservation == nil, let item = self.items.first else { return nil }
        let reservation = Reservation(id: UUID(), item: item)
        self.reservation = reservation
        return reservation
    }

    @discardableResult
    public func commit(_ reservation: Reservation) -> Bool {
        guard self.reservation?.id == reservation.id else { return false }
        self.items.removeFirst()
        self.reservation = nil
        return true
    }

    @discardableResult
    public func rollback(_ reservation: Reservation) -> Bool {
        guard self.reservation?.id == reservation.id else { return false }
        self.reservation = nil
        return true
    }

    public func clear() {
        self.reservation = nil
        self.items.removeAll()
    }
}
