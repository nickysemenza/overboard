import AppKit
import OverboardCore
@testable import OverboardMac
import Testing

extension PastebackSessionTests {
    @Test func failedPublicationDoesNotMarkUsedAndRestoresBackup() async throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        self.write("original", to: board)
        let store = try self.makeStore()
        let item = try await self.capture("selected", store: store)
        let service = PastebackService(store: store, pasteboard: board, writeObjects: { _ in false })
        #expect(await service.copy(item) == .failed)
        #expect(try await store.recent().first?.useCount == item.useCount)
        #expect(board.string(forType: .string) == "original")
    }

    @Test func successfulPublicationMarksUsedExactlyOnce() async throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        let store = try self.makeStore()
        let item = try await self.capture("selected", store: store)
        let service = PastebackService(store: store, pasteboard: board)
        #expect(await service.copy(item) == .copied)
        #expect(try await store.recent().first?.useCount == item.useCount + 1)
        #expect(board.string(forType: .string) == "selected")
    }

    @Test func deletedClipFailsWithoutChangingClipboard() async throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        self.write("original", to: board)
        let store = try self.makeStore()
        let item = try await self.capture("selected", store: store)
        try await store.delete(id: item.id)
        let service = PastebackService(store: store, pasteboard: board)
        #expect(await service.copy(item) == .failed)
        #expect(board.string(forType: .string) == "original")
    }

    @Test func failedWriteCannotRollbackOverForeignWriter() async throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        self.write("original", to: board)
        let service = try PastebackService(
            store: self.makeStore(), pasteboard: board,
            writeObjects: { _ in self.write("foreign", to: board); return false }
        )
        #expect(await service.pasteText("selected", into: nil, restoreClipboard: true) == .failed)
        #expect(board.string(forType: .string) == "foreign")
    }

    @Test func foreignWriteDuringFlushCancelsWithoutPublishingOrMarkingUsed() async throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        let store = try self.makeStore()
        let item = try await self.capture("selected", store: store)
        let service = PastebackService(store: store, pasteboard: board)
        service.beforePublication = { self.write("foreign", to: board) }
        #expect(await service.copy(item) == .cancelled)
        #expect(try await store.recent().first?.useCount == item.useCount)
        #expect(board.string(forType: .string) == "foreign")
    }

    @Test func cancellationDuringFlushNeverPublishesOrMarksUsed() async throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        self.write("original", to: board)
        let store = try self.makeStore()
        let item = try await self.capture("selected", store: store)
        let gate = PastebackTestGate()
        let service = PastebackService(store: store, pasteboard: board)
        service.beforePublication = { await gate.wait() }
        let task = Task { await service.copy(item) }
        await gate.waitUntilEntered()
        task.cancel()
        gate.release()
        #expect(await task.value == .cancelled)
        #expect(try await store.recent().first?.useCount == item.useCount)
        #expect(board.string(forType: .string) == "original")
    }

    @Test func failedFlushNeverPublishesOrMarksUsed() async throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        self.write("original", to: board)
        let store = try self.makeStore()
        let item = try await self.capture("selected", store: store)
        let service = PastebackService(store: store, pasteboard: board)
        service.beforePublication = { throw FlushFailure.unavailable }
        #expect(await service.copy(item) == .failed)
        #expect(try await store.recent().first?.useCount == item.useCount)
        #expect(board.string(forType: .string) == "original")
    }

    @Test func copyTextFlushesPendingCaptureWithoutActivatingOrDispatching() async throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: board)
        self.write("pending", to: board)
        var activations = 0
        var dispatches = 0
        let service = try PastebackService(
            store: self.makeStore(), pasteboard: board, isTrusted: { true },
            activate: { _ in activations += 1; return true },
            dispatch: { dispatches += 1; return true }
        )
        service.beforePublication = { monitor.flushPendingCapture() }
        #expect(await service.copyText("selected") == .copied)
        var iterator = monitor.snapshots.makeAsyncIterator()
        let snapshot = try #require(await iterator.next())
        #expect(snapshot.reps.first(where: { $0.uti == WellKnownUTI.plainText })?.data == Data("pending".utf8))
        #expect(board.string(forType: .string) == "selected")
        #expect(monitor.capturePendingSnapshot() == nil)
        #expect(activations == 0)
        #expect(dispatches == 0)
    }
}

private enum FlushFailure: Error {
    case unavailable
}
