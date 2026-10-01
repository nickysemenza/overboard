import Foundation

actor LifecycleReadGate<Value: Sendable> {
    private(set) var count = 0
    private var reads: [Int: CheckedContinuation<Value, Never>] = [:]
    private var observers: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func read() async -> Value {
        self.count += 1
        let ordinal = self.count
        for observer in self.observers.removeValue(forKey: ordinal) ?? [] {
            observer.resume()
        }
        return await withCheckedContinuation { self.reads[ordinal] = $0 }
    }

    func waitForReads(_ count: Int) async {
        guard self.count < count else { return }
        await withCheckedContinuation { self.observers[count, default: []].append($0) }
    }

    func release(_ ordinal: Int = 1, returning value: Value) {
        self.reads.removeValue(forKey: ordinal)?.resume(returning: value)
    }
}

@MainActor
final class LifecycleTestClock {
    var now = Date(timeIntervalSince1970: 2_000_000_000)

    func advance(_ interval: TimeInterval = 2) {
        self.now = self.now.addingTimeInterval(interval)
    }
}
