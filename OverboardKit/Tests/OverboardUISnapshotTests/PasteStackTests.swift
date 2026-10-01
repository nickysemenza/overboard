import Foundation
import OverboardCore
@testable import OverboardUI
import Testing

@MainActor
struct PasteStackTests {
    private func item(_ id: String) -> ClipItem {
        ClipItem(
            id: id, contentHash: id, kind: .text, previewText: id,
            sourceBundleID: nil, sourceAppName: nil, byteSize: 1,
            createdAt: .distantPast, lastUsedAt: .distantPast, updatedAt: .distantPast
        )
    }

    @Test func reservationCommitsOnceAndPreservesFIFO() throws {
        let stack = PasteStack()
        stack.push(self.item("first"))
        stack.push(self.item("second"))
        let reservation = try #require(stack.reserveNext())
        #expect(reservation.item.id == "first")
        #expect(stack.count == 2)
        #expect(stack.reserveNext() == nil)
        #expect(stack.popNext() == nil)
        #expect(stack.commit(reservation))
        #expect(!stack.commit(reservation))
        #expect(!stack.rollback(reservation))
        #expect(stack.popNext()?.id == "second")
        #expect(stack.popNext() == nil)
    }

    @Test func rollbackKeepsFrontItemAndInvalidatesOldToken() throws {
        let stack = PasteStack()
        stack.push(self.item("first"))
        let first = try #require(stack.reserveNext())
        stack.push(self.item("second"))
        #expect(stack.rollback(first))
        let retry = try #require(stack.reserveNext())
        #expect(retry.item.id == "first")
        #expect(!stack.commit(first))
        #expect(!stack.rollback(first))
        #expect(stack.commit(retry))
        #expect(stack.items.map(\.id) == ["second"])
    }

    @Test func clearInvalidatesReservationEvenWhenSameItemIsRequeued() throws {
        let stack = PasteStack()
        stack.push(self.item("same"))
        let stale = try #require(stack.reserveNext())
        stack.clear()
        stack.push(self.item("same"))
        let current = try #require(stack.reserveNext())
        #expect(!stack.commit(stale))
        #expect(!stack.rollback(stale))
        #expect(stack.count == 1)
        #expect(stack.commit(current))
    }

    @Test func reservationCannotAffectAnotherStack() throws {
        let first = PasteStack()
        let second = PasteStack()
        first.push(self.item("same"))
        second.push(self.item("same"))
        let reservation = try #require(first.reserveNext())
        _ = second.reserveNext()
        #expect(!second.commit(reservation))
        #expect(!second.rollback(reservation))
        #expect(second.count == 1)
    }
}
