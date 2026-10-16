import CoreServices
import Foundation
import OverboardCore

/// FSEvents watching and the debounced incremental refresh it drives.
extension FileIndexService {
    func scheduleRefresh(delay: Duration = .seconds(3)) {
        guard !self.isIndexing, !self.isStopped, self.refreshTask == nil else { return }
        let lifecycle = self.lifecycleGeneration
        self.refreshTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, !self.isStopped, self.lifecycleGeneration == lifecycle,
                  let index = self.index else { return }
            await self.performRefresh(index: index)
        }
    }

    /// Scans every dirty directory against the active roots, then folds the
    /// result into the published state. Runs on the debounce timer fired by
    /// `scheduleRefresh()`.
    private func performRefresh(index: FileNameIndex) async {
        let directories = self.consumeDirtyChanges()
        let lifecycle = self.lifecycleGeneration
        self.isIndexing = true
        defer {
            if self.lifecycleGeneration == lifecycle, !self.isStopped {
                self.isIndexing = false
                self.refreshTask = nil
                self.signalReconcile()
                if !Task.isCancelled, !self.dirtyPaths.isEmpty {
                    self.scheduleRefresh(delay: .seconds(1))
                }
            }
        }
        for directory in directories {
            guard !Task.isCancelled else { return }
            guard await self.refreshDirectory(directory, index: index) else { return }
        }
        guard !Task.isCancelled else { return }
        let fileCount = await (try? index.count()) ?? self.fileCount
        guard !Task.isCancelled, self.lifecycleGeneration == lifecycle, !self.isStopped else { return }
        self.fileCount = fileCount
        self.status = Self.statusMessage(fileCount: self.fileCount, hasIssues: !self.issues.isEmpty)
        self.onChange()
    }

    /// Scans one dirty directory under whichever active root claims it.
    /// Returns `true` to keep processing the remaining directories — whether
    /// this one was skipped (no root claims it) or scanned successfully —
    /// and `false` to abort the whole refresh, matching the original
    /// early-return behavior when the worker is cancelled or throws.
    private func refreshDirectory(_ change: FileIndexChange, index: FileNameIndex) async -> Bool {
        let roots = self.activeRoots
        let exclusions = self.activeExclusions
        let refresh = self.operations.refresh
        let worker = Task.detached(priority: .utility) {
            try await refresh(FileIndexRefreshRequest(
                path: change.path, roots: roots, exclusions: exclusions, index: index, scope: change.scope
            ))
        }
        do {
            let failures = try await withTaskCancellationHandler { try await worker.value } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return false }
            self.issues = Array((self.issues + failures).suffix(12))
            return true
        } catch {
            return false
        }
    }

    func watch(_ roots: [URL]) {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        self.eventStream = FSEventStreamCreate(nil, { _, pointer, count, paths, flags, _ in
            guard let pointer else { return }
            // Stream is explicitly delivered on the main queue. Ignore our own
            // index/clipboard databases and excluded build trees to avoid loops.
            MainActor.assumeIsolated {
                let service = Unmanaged<FileIndexService>.fromOpaque(pointer).takeUnretainedValue()
                guard !service.isStopped else { return }
                let changed = unsafeBitCast(paths, to: NSArray.self).compactMap { $0 as? String }
                service.enqueueEvents(changed, flags: Array(UnsafeBufferPointer(start: flags, count: count)))
                if !service.dirtyPaths.isEmpty {
                    service.scheduleRefresh()
                }
            }
        }, &context, roots.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagFileEvents))
        if let stream = self.eventStream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    func stopWatching() {
        guard let stream = self.eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.eventStream = nil
    }
}
