import Foundation
import Synchronization

public final class CaptureAdmission: Sendable, Equatable {
    private let active = Mutex(true)

    public init() {}

    public func invalidate() {
        self.active.withLock { $0 = false }
    }

    public func check() throws {
        guard self.active.withLock({ $0 }) else { throw CancellationError() }
    }

    public static func == (lhs: CaptureAdmission, rhs: CaptureAdmission) -> Bool {
        lhs === rhs
    }
}
