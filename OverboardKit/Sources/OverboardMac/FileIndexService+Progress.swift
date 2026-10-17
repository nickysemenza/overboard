import CoreServices
import Darwin
import Foundation
import OverboardCore

/// Persisted scan progress: lets a relaunch replay FSEvents history for roots
/// whose index is already complete instead of re-enumerating them.
///
/// The invariant everything here protects is "a saved event ID never runs ahead
/// of the index". Missing an ID costs a longer replay; passing one costs a
/// silently stale index, which nothing would ever repair. So every path that
/// moves an ID forward demands that nothing is dirty, no scan or refresh is in
/// flight, no history replay is pending, and no earlier pass was aborted.
extension FileIndexService {
    /// Bump when the scanner's notion of what to index changes (noise rules,
    /// what counts as hidden, ...): saved progress then stops matching and every
    /// root is scanned in full once. Not tied to the app build, because a
    /// dogfood relaunch is exactly the case this exists to make cheap.
    nonisolated static let scanStateVersion = 1

    /// FSEvents history is pruned by fseventsd without any signal to a stream
    /// that asks for an ID older than what remains, so progress older than this
    /// is not trusted.
    nonisolated static let maxResumeAge: TimeInterval = 7 * 24 * 60 * 60

    /// Minimum spacing between progress checkpoints, which flush the streams
    /// and write the database.
    nonisolated static let checkpointInterval: TimeInterval = 60

    /// Stable across launches (unlike `Hasher`): FNV-1a over everything that
    /// changes which files get indexed.
    nonisolated static func configHash(roots: [URL], exclusions: [String]) -> String {
        let normalizedExclusions = exclusions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let lines = ["v\(self.scanStateVersion)"] + roots.map(\.path).sorted() + ["--"] + normalizedExclusions.sorted()
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in lines.joined(separator: "\n").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    /// The volume's FSEvents UUID. Event IDs mean nothing on another volume (or
    /// after the volume's event log was reset), so progress carries this.
    nonisolated static func deviceUUID(of root: URL) -> String? {
        var info = stat()
        guard stat(root.path, &info) == 0,
              let uuid = FSEventsCopyUUIDForDevice(info.st_dev),
              let string = CFUUIDCreateString(nil, uuid)
        else { return nil }
        return string as String
    }

    /// The event ID to replay from for each root whose saved progress is still
    /// trustworthy, keyed by root path. Roots absent from the result need a
    /// full scan.
    nonisolated static func resumePoints(
        roots: [URL], states: [FileIndexScanState], configHash: String, now: Date = Date(),
        currentEventID: UInt64 = FSEventsGetCurrentEventId(),
        deviceUUID: (URL) -> String? = FileIndexService.deviceUUID(of:)
    ) -> [String: UInt64] {
        var points: [String: UInt64] = [:]
        for root in roots {
            guard let state = states.first(where: { $0.root == root.path.precomposedStringWithCanonicalMapping }),
                  state.configHash == configHash,
                  state.eventID <= currentEventID,
                  now.timeIntervalSince(state.completedAt) < self.maxResumeAge,
                  deviceUUID(root) == state.deviceUUID
            else { continue }
            points[root.path] = state.eventID
        }
        return points
    }

    func resetProgress() {
        self.isProgressBlocked = false
        self.verifiedEventID = 0
        self.persistedEventID = 0
        self.lastCheckpoint = nil
        self.pendingHistoryStreams = 0
    }

    /// Whether the index provably reflects every event delivered so far.
    private var isIdleForCheckpoint: Bool {
        !self.isIndexing && self.refreshTask == nil && self.dirtyPaths.isEmpty && !self.isProgressBlocked
            && self.pendingHistoryStreams == 0 && !self.eventStreams.isEmpty && self.index != nil
    }

    /// Advances the saved event ID to "now", once the index has caught up.
    ///
    /// "Now" is only safe because of the flush: the roots may be split across
    /// streams that deliver independently, so having handled event 100 from one
    /// stream says nothing about event 95 on another. Flushing makes every
    /// stream hand over what it holds; hopping through the (serial) event queue
    /// before returning to main guarantees those callbacks' own main-actor hops
    /// have already been queued ahead of the completion check, which then
    /// re-verifies that nothing became dirty in the meantime.
    func checkpointProgressIfIdle() {
        guard self.isIdleForCheckpoint else { return }
        if let last = self.lastCheckpoint, Date().timeIntervalSince(last) < Self.checkpointInterval {
            return
        }
        self.lastCheckpoint = Date()
        let candidate = UInt64(FSEventsGetCurrentEventId())
        let generation = self.lifecycleGeneration
        for stream in self.eventStreams {
            FSEventStreamFlushSync(stream)
        }
        self.eventQueue.async {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.completeCheckpoint(candidate, generation: generation) }
            }
        }
    }

    private func completeCheckpoint(_ eventID: UInt64, generation: Int) {
        guard generation == self.lifecycleGeneration, !self.isStopped, self.isIdleForCheckpoint else { return }
        self.verifiedEventID = max(self.verifiedEventID, eventID)
        self.persistVerifiedProgress()
    }

    /// Called as the service stops: persists the last verified ID if the index
    /// is still caught up. Never recomputes one; a stop cannot flush streams.
    func persistProgressOnStop() {
        guard !self.isIndexing, self.refreshTask == nil, self.dirtyPaths.isEmpty, !self.isProgressBlocked,
              self.pendingHistoryStreams == 0
        else { return }
        self.persistVerifiedProgress()
    }

    private func persistVerifiedProgress() {
        guard let index, self.verifiedEventID > self.persistedEventID else { return }
        let eventID = self.verifiedEventID
        let configHash = self.activeConfigHash
        self.persistedEventID = eventID
        Task { try? await index.advanceScanStates(to: eventID, configHash: configHash) }
    }

    /// Scans a single root and folds its failures/count into the published state.
    /// A clean scan records the event ID taken *before* it began: changes made
    /// while it ran are then replayed rather than assumed seen.
    func scanRoot(_ root: URL, exclusions: [String], configHash: String, index: FileNameIndex) async throws {
        guard !Task.isCancelled else { return }
        self.status = "Indexing \(Self.locationName(root))…"
        let generation = UUID().uuidString
        let startEventID = UInt64(FSEventsGetCurrentEventId())
        try await index.clearScanState(root: root.path)
        let request = FileIndexScanRequest(
            root: root, exclusions: exclusions, generation: generation, index: index, roots: self.activeRoots
        )
        let scan = self.operations.scan
        // Discovery is a one-off bulk walk nobody is waiting on; incremental
        // refreshes stay at `.utility` because a user just changed something.
        let worker = Task.detached(priority: .background) {
            try await scan(request)
        }
        let failures = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return }
        let fileCount = try await index.count()
        try Task.checkCancellation()
        if failures.isEmpty, let deviceUUID = Self.deviceUUID(of: root) {
            try await index.saveScanState(FileIndexScanState(
                root: root.path, deviceUUID: deviceUUID, eventID: startEventID, configHash: configHash
            ))
        }
        self.issues += failures
        self.fileCount = fileCount
        self.onChange()
    }
}
