import Foundation
import os

final nonisolated class BrowserProvenanceRequest: Sendable {
    private struct State {
        var continuation: CheckedContinuation<String?, Never>?
        var value: String?
        var completed = false
        var tasks: [Task<Void, Never>] = []
    }

    private struct Completion {
        var continuation: CheckedContinuation<String?, Never>?
        var tasks: [Task<Void, Never>]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(_ continuation: CheckedContinuation<String?, Never>) {
        let result = self.state.withLock { state in
            if state.completed {
                return (true, state.value)
            }
            state.continuation = continuation
            return (false, nil as String?)
        }
        if result.0 {
            continuation.resume(returning: result.1)
        }
    }

    func register(_ task: Task<Void, Never>) {
        let completed = self.state.withLock { state in
            guard !state.completed else { return true }
            state.tasks.append(task)
            return false
        }
        if completed {
            task.cancel()
        }
    }

    func finish(_ value: String?) {
        let completion = self.state.withLock { state -> Completion? in
            guard !state.completed else { return nil }
            state.completed = true
            state.value = value
            let completion = Completion(continuation: state.continuation, tasks: state.tasks)
            state.continuation = nil
            state.tasks.removeAll()
            return completion
        }
        guard let completion else { return }
        for task in completion.tasks {
            task.cancel()
        }
        completion.continuation?.resume(returning: value)
    }
}
