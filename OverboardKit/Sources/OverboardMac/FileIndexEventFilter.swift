import CoreServices
import Foundation

/// One FSEvents callback's worth of events that survived the prefilter, plus
/// the facts the main actor needs that the surviving paths alone don't carry.
nonisolated struct FileIndexEventBatch: Sendable {
    var paths: [String] = []
    var flags: [FSEventStreamEventFlags] = []
    /// UserDropped / KernelDropped / EventIdsWrapped: individual paths can no
    /// longer be trusted, so every root needs a recursive rescan.
    var lost = false
    /// The end of a `sinceWhen` replay: everything after it is live.
    var historyDone = false
    /// Highest event ID in the callback, counting the events the filter
    /// rejected: they need no indexing, so they are "processed" on arrival.
    var lastEventID: FSEventStreamEventId = 0
}

/// Decides, off the main thread and without building a `URL`, which FSEvents
/// are worth waking the main actor for. The home stream reports every cache
/// write under `~/Library` and every dot-directory touch (hundreds per second
/// in bursts); all of them used to be rejected only after paying for URL
/// standardization on main. Ownership itself is `FileIndexPathPolicy`'s, so this
/// type can drop work but never disagree about what is indexed.
nonisolated struct FileIndexEventFilter: Sendable {
    private let policy: FileIndexPathPolicy
    private let rootPaths: [String]

    init(policy: FileIndexPathPolicy) {
        self.policy = policy
        self.rootPaths = policy.rootPaths
    }

    static let lostFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
            kFSEventStreamEventFlagEventIdsWrapped
    )

    /// The refresh scope an event implies. Shared with `enqueueEvents` so the
    /// filter's "would this recover a parent of a nested root" question uses the
    /// same rule as the queue.
    static func scope(for flags: FSEventStreamEventFlags) -> FileIndexRefreshScope {
        let recover = flags & FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
        ) != 0
        let directory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        let introduced = flags & FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed
        ) != 0
        if recover || (directory && introduced) {
            return .subtree
        }
        return directory ? .children : .entry
    }

    func accepts(_ rawPath: String, flags: FSEventStreamEventFlags) -> Bool {
        var path = Self.normalized(rawPath)
        if path.utf8.count > 1, path.utf8.last == Self.slash {
            path.removeLast()
        }
        // A .gitignore edit re-judges noise for its whole directory, so the
        // directory (not the hidden file) is what must be owned.
        if let slash = path.utf8.lastIndex(of: Self.slash),
           path.utf8[path.utf8.index(after: slash)...].elementsEqual(".gitignore".utf8)
        {
            let parent = String(path[..<slash])
            return self.policy.owner(ofPath: parent.isEmpty ? "/" : parent) != nil
        }
        if self.policy.owner(ofPath: path) != nil {
            return true
        }
        // Recovery on an ancestor of a nested root (say `~/Library`) re-queues
        // that root even though the ancestor itself is not indexed.
        guard Self.scope(for: flags) == .subtree else { return false }
        let prefix = path == "/" ? path : path + "/"
        return self.rootPaths.contains { $0.hasPrefix(prefix) }
    }

    private static let slash = UInt8(ascii: "/")

    /// FSEvents paths are almost always ASCII and already standardized; only
    /// pay for Unicode normalization when a path actually needs it.
    private static func normalized(_ path: String) -> String {
        path.utf8.allSatisfy { $0 < 0x80 } ? path : path.precomposedStringWithCanonicalMapping
    }

    func batch(paths: [String], flags: [FSEventStreamEventFlags], lastEventID: FSEventStreamEventId)
        -> FileIndexEventBatch
    {
        var batch = FileIndexEventBatch(lastEventID: lastEventID)
        batch.historyDone = flags.contains { $0 & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 }
        if flags.contains(where: { $0 & Self.lostFlags != 0 }) {
            batch.lost = true
            return batch
        }
        for (path, flag) in zip(paths, flags) where self.accepts(path, flags: flag) {
            batch.paths.append(path)
            batch.flags.append(flag)
        }
        return batch
    }
}

/// The object FSEvents' C callback talks to. Everything it does happens on the
/// stream's private serial queue; the only crossing to the main actor is the
/// `deliver` closure, once per callback.
final nonisolated class FileIndexEventSink: Sendable {
    let filter: FileIndexEventFilter
    let generation: Int
    private let deliver: @Sendable (FileIndexEventBatch, Int) -> Void

    init(filter: FileIndexEventFilter, generation: Int,
         deliver: @escaping @Sendable (FileIndexEventBatch, Int) -> Void)
    {
        self.filter = filter
        self.generation = generation
        self.deliver = deliver
    }

    /// The C callback. Non-capturing, so it lives here rather than in the
    /// main-actor service; `info` is the sink the stream was created with.
    static let callback: FSEventStreamCallback = { _, info, count, paths, flags, eventIDs in
        guard let info else { return }
        let sink = Unmanaged<FileIndexEventSink>.fromOpaque(info).takeUnretainedValue()
        let changed = unsafeBitCast(paths, to: NSArray.self).compactMap { $0 as? String }
        sink.receive(
            paths: changed,
            flags: Array(UnsafeBufferPointer(start: flags, count: count)),
            eventIDs: Array(UnsafeBufferPointer(start: eventIDs, count: count))
        )
    }

    /// Context retain/release live here, not in the main-actor service: FSEvents
    /// invokes them from its own queue during stream teardown, and a closure
    /// formed in a main-actor method would trap its isolation check there.
    static let retain: CFAllocatorRetainCallBack = { info in
        guard let info else { return nil }
        _ = Unmanaged<FileIndexEventSink>.fromOpaque(info).retain()
        return info
    }

    static let release: CFAllocatorReleaseCallBack = { info in
        guard let info else { return }
        Unmanaged<FileIndexEventSink>.fromOpaque(info).release()
    }

    func receive(paths: [String], flags: [FSEventStreamEventFlags], eventIDs: [FSEventStreamEventId]) {
        let batch = self.filter.batch(paths: paths, flags: flags, lastEventID: eventIDs.max() ?? 0)
        self.deliver(batch, self.generation)
    }
}
