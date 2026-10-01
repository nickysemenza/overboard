import Foundation
import OverboardCore

public final class BoundedEnrichmentQueue {
    private struct Work {
        let item: ClipItem
        let snapshot: PasteboardSnapshot
        var byteSize: Int {
            self.snapshot.reps.reduce(0) { $0 + $1.data.count }
        }
    }

    private let capacity: Int
    private let byteLimit: Int
    private let process: @Sendable (ClipItem, PasteboardSnapshot) async -> Void
    private var pending: [Work] = []
    private var task: Task<Void, Never>?
    private var generation = 0
    private var activeBytes = 0
    public private(set) var isRunning = false
    public var pendingCount: Int {
        self.pending.count
    }

    public var retainedBytes: Int {
        self.activeBytes + self.pending.reduce(0) { $0 + $1.byteSize }
    }

    public init(
        capacity: Int = 8,
        byteLimit: Int = 64 * 1024 * 1024,
        process: @escaping @Sendable (ClipItem, PasteboardSnapshot) async -> Void
    ) {
        self.capacity = max(1, capacity)
        self.byteLimit = max(1, byteLimit)
        self.process = process
    }

    public func start() {
        self.isRunning = true
        self.runIfNeeded()
    }

    public func stop() {
        self.isRunning = false
        self.generation += 1
        self.task?.cancel()
        self.pending.removeAll()
    }

    @discardableResult
    public func enqueue(item: ClipItem, snapshot: PasteboardSnapshot) -> Bool {
        let work = Work(item: item, snapshot: snapshot)
        guard self.isRunning, work.byteSize <= self.byteLimit - self.activeBytes else { return false }
        while !self.pending.isEmpty,
              self.pending.count >= self.capacity || self.retainedBytes + work.byteSize > self.byteLimit
        {
            self.pending.removeFirst()
        }
        self.pending.append(work)
        self.runIfNeeded()
        return true
    }

    private func runIfNeeded() {
        guard self.task == nil, self.isRunning else { return }
        let generation = self.generation
        self.task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.isRunning, self.generation == generation, !self.pending.isEmpty {
                let work = self.pending.removeFirst()
                self.activeBytes = work.byteSize
                await self.process(work.item, work.snapshot)
                self.activeBytes = 0
            }
            self.task = nil
            self.runIfNeeded()
        }
    }

    isolated deinit { self.task?.cancel() }
}
