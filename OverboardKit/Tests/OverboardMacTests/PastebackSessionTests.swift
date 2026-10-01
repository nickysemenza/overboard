import AppKit
import OverboardCore
@testable import OverboardMac
import Testing

@MainActor
struct PastebackSessionTests {
    func makeStore() throws -> ClipStore {
        let queue = try OverboardDatabase.openInMemory()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return try ClipStore(dbWriter: queue, blobs: BlobStore(directory: directory))
    }

    func board() -> NSPasteboard {
        NSPasteboard(name: .init("overboard-wave1-tests-\(UUID().uuidString)"))
    }

    func write(_ text: String, to board: NSPasteboard) {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    func capture(_ text: String, store: ClipStore) async throws -> ClipItem {
        try #require(await store.ingest(PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data(text.utf8))],
            sourceBundleID: nil, sourceAppName: nil
        )))
    }

    @Test func cancelledActivationNeverDispatchesAndRestoresOwnedClipboard() async throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        self.write("original", to: board)
        let gate = PastebackTestGate()
        var dispatches = 0
        let service = try PastebackService(
            store: self.makeStore(), pasteboard: board, isTrusted: { true },
            dispatch: { dispatches += 1; return true }, sleep: { _ in await gate.wait() }
        )
        let task = Task { await service.pasteText("selected", into: nil, restoreClipboard: true) }
        await gate.waitUntilEntered()
        task.cancel()
        gate.release()
        #expect(await task.value == .cancelled)
        #expect(dispatches == 0)
        #expect(board.string(forType: .string) == "original")
    }

    @Test func explicitCancelStopsActivationAndPreservesForeignClipboard() async throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        self.write("original", to: board)
        let gate = PastebackTestGate()
        var dispatches = 0
        let service = try PastebackService(
            store: self.makeStore(), pasteboard: board, isTrusted: { true },
            dispatch: { dispatches += 1; return true }, sleep: { _ in await gate.wait() }
        )
        let task = Task { await service.pasteText("selected", into: nil, restoreClipboard: true) }
        await gate.waitUntilEntered()
        self.write("foreign", to: board)
        service.cancel()
        gate.release()
        #expect(await task.value == .cancelled)
        #expect(dispatches == 0)
        #expect(board.string(forType: .string) == "foreign")
    }

    @Test func dispatchOutcomeIsNotReturnedBeforeDispatch() async throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        let gate = PastebackTestGate()
        var dispatches = 0
        var completed = false
        let service = try PastebackService(
            store: self.makeStore(), pasteboard: board, isTrusted: { true },
            dispatch: { dispatches += 1; return true }, sleep: { _ in await gate.wait() }
        )
        let task = Task {
            let result = await service.pasteText("selected", into: nil, restoreClipboard: false)
            completed = true
            return result
        }
        await gate.waitUntilEntered()
        #expect(!completed)
        #expect(dispatches == 0)
        gate.release()
        #expect(await task.value == .pasted)
        #expect(dispatches == 1)
    }

    @Test func permissionFallbackCopiesWithoutActivatingOrDispatching() async throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        var activations = 0
        var dispatches = 0
        let service = try PastebackService(
            store: self.makeStore(), pasteboard: board,
            activate: { _ in activations += 1; return true },
            dispatch: { dispatches += 1; return true }
        )
        #expect(await service.pasteText("selected", into: nil, restoreClipboard: true) == .copiedOnly)
        service.cancel()
        #expect(board.string(forType: .string) == "selected")
        #expect(activations == 0)
        #expect(dispatches == 0)
    }

    @Test func wrongTargetFailsBeforeDispatchAndRestoresClipboard() async throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        self.write("original", to: board)
        var dispatches = 0
        let service = try PastebackService(
            store: self.makeStore(), pasteboard: board, isTrusted: { true },
            isTargetActive: { _ in false }, dispatch: { dispatches += 1; return true }, sleep: { _ in }
        )
        #expect(await service.pasteText("selected", into: nil, restoreClipboard: true) == .failed)
        #expect(dispatches == 0)
        #expect(board.string(forType: .string) == "original")
    }

    @Test func newerPasteCancelsOlderActivationWithoutRestoringOverIt() async throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        self.write("original", to: board)
        let gate = PastebackTestGate()
        var activations = 0
        var dispatches = 0
        let service = try PastebackService(
            store: self.makeStore(), pasteboard: board, isTrusted: { true },
            dispatch: { dispatches += 1; return true },
            sleep: { _ in
                activations += 1
                if activations == 1 {
                    await gate.wait()
                }
            }
        )
        let first = Task { await service.pasteText("first", into: nil, restoreClipboard: true) }
        await gate.waitUntilEntered()
        #expect(await service.pasteText("second", into: nil, restoreClipboard: false) == .pasted)
        gate.release()
        #expect(await first.value == .cancelled)
        #expect(dispatches == 1)
        #expect(board.string(forType: .string) == "second")
    }

    @Test func foreignWriteBeforeNextPasteBecomesNewBackup() async throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        self.write("original", to: board)
        let gate = PastebackTestGate()
        let service = try PastebackService(
            store: self.makeStore(), pasteboard: board, isTrusted: { true },
            sleep: { duration in
                if duration != .milliseconds(90) {
                    await gate.wait()
                }
            },
            consumptionTimeout: .zero
        )
        #expect(await service.pasteText("first", into: nil, restoreClipboard: true) == .pasted)
        await gate.waitUntilEntered()
        self.write("foreign", to: board)
        #expect(await service.pasteText("second", into: nil, restoreClipboard: true) == .pasted)
        service.cancel()
        gate.release()
        #expect(board.string(forType: .string) == "foreign")
    }

    @Test func newerOwnedPasteReusesOriginalBackup() async throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        self.write("original", to: board)
        let gate = PastebackTestGate()
        let service = try PastebackService(
            store: self.makeStore(), pasteboard: board, isTrusted: { true },
            sleep: { duration in
                if duration != .milliseconds(90) {
                    await gate.wait()
                }
            },
            consumptionTimeout: .zero
        )
        #expect(await service.pasteText("first", into: nil, restoreClipboard: true) == .dispatched)
        await gate.waitUntilEntered()
        #expect(await service.pasteText("second", into: nil, restoreClipboard: true) == .dispatched)
        service.cancel()
        gate.release()
        #expect(board.string(forType: .string) == "original")
    }

    @Test func restorationNeverOverwritesNewerForeignClipboard() async throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        self.write("original", to: board)
        let gate = PastebackTestGate()
        let service = try PastebackService(
            store: self.makeStore(), pasteboard: board, isTrusted: { true },
            sleep: { duration in
                if duration != .milliseconds(90) {
                    await gate.wait()
                }
            },
            consumptionTimeout: .zero
        )
        #expect(await service.pasteText("selected", into: nil, restoreClipboard: true) == .pasted)
        await gate.waitUntilEntered()
        self.write("foreign", to: board)
        gate.release()
        await service.drain()
        #expect(board.string(forType: .string) == "foreign")
    }

    @Test func restorationPreservesOrderedItemsAndAllOriginalFlavors() async throws {
        let board = self.board()
        defer { board.releaseGlobally() }
        let original = ["first", "second"].map { text in
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            item.setData(Data("<b>\(text)</b>".utf8), forType: .html)
            return item
        }
        board.clearContents()
        board.writeObjects(original)
        let service = try PastebackService(
            store: self.makeStore(), pasteboard: board, isTrusted: { true },
            sleep: { _ in }, consumptionTimeout: .zero
        )
        #expect(await service.pasteText("selected", into: nil, restoreClipboard: true) == .pasted)
        await service.drain()
        let restored = try #require(board.pasteboardItems)
        #expect(restored.map { $0.string(forType: .string) } == ["first", "second"])
        #expect(restored.compactMap { $0.data(forType: .html) } == ["first", "second"].map {
            Data("<b>\($0)</b>".utf8)
        })
    }
}

@MainActor
final class PastebackTestGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var entered = false
    private var released = false

    func wait() async {
        self.entered = true
        if self.released {
            return
        }
        await withCheckedContinuation { self.continuations.append($0) }
    }

    func waitUntilEntered() async {
        while !self.entered {
            await Task.yield()
        }
    }

    func release() {
        self.released = true
        for continuation in self.continuations {
            continuation.resume()
        }
        self.continuations.removeAll()
    }
}
