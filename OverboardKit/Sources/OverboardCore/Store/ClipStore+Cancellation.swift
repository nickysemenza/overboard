import GRDB
import Synchronization

private final class StoreWriteCancellation: Sendable {
    private let cancelled = Mutex(false)

    func cancel() {
        self.cancelled.withLock { $0 = true }
    }

    func check() throws {
        if self.cancelled.withLock({ $0 }) {
            throw CancellationError()
        }
    }
}

extension ClipStore {
    func writeCancellable<Result: Sendable>(
        _ updates: @escaping @Sendable (Database) throws -> Result
    ) async throws -> Result {
        let cancellation = StoreWriteCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await self.dbWriter.write { db in
                try cancellation.check()
                let result = try updates(db)
                try cancellation.check()
                return result
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
