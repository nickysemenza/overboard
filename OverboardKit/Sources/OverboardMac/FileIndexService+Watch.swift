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
        let directories = self.consumeDirtyDirectories()
        let lifecycle = self.lifecycleGeneration
        self.isIndexing = true
        defer {
            if self.lifecycleGeneration == lifecycle, !self.isStopped {
                self.isIndexing = false
                self.refreshTask = nil
                self.signalReconcile()
                if !Task.isCancelled, !self.dirtyPaths.isEmpty {
                    self.scheduleRefresh(delay: .zero)
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

    /// Drains a bounded oldest-first batch without promoting files to parent scans.
    func consumeDirtyDirectories() -> [URL] {
        let changed = self.dirtyPaths.sorted {
            self.dirtyOrder[$0, default: 0] < self.dirtyOrder[$1, default: 0]
        }.prefix(32)
        for path in changed {
            self.dirtyPaths.remove(path)
            self.dirtySubtrees.remove(path)
            self.dirtyOrder.removeValue(forKey: path)
        }
        return changed.map { URL(fileURLWithPath: $0) }
    }

    func enqueueChange(_ rawPath: String, subtree: Bool = false) {
        guard !self.isStopped else { return }
        let path = URL(fileURLWithPath: rawPath).standardized.path.precomposedStringWithCanonicalMapping
        let url = URL(fileURLWithPath: path)
        guard let root = FileMetadataScanner.owner(of: url, roots: self.activeRoots, exclusions: self.activeExclusions)
        else { return }
        if self.dirtySubtrees.contains(where: {
            (path == $0 || path.hasPrefix($0 + "/")) &&
                FileMetadataScanner.owner(of: URL(fileURLWithPath: $0), roots: self.activeRoots,
                                          exclusions: self.activeExclusions)?.path == root.path
        }) {
            return
        }
        if self.dirtyPaths.count >= 512 {
            for activeRoot in self.activeRoots where self.dirtyPaths.contains(where: {
                FileMetadataScanner.owner(of: URL(fileURLWithPath: $0), roots: self.activeRoots,
                                          exclusions: self.activeExclusions)?.path == activeRoot.path
            }) {
                self.coalesceSubtree(activeRoot.path, owner: activeRoot)
            }
            self.coalesceSubtree(root.path, owner: root)
        } else if subtree {
            self.coalesceSubtree(path, owner: root)
        } else {
            self.insertDirty(path)
        }
    }

    private func insertDirty(_ path: String) {
        if self.dirtyPaths.insert(path).inserted {
            self.dirtyOrder[path] = self.nextDirtyOrder
            self.nextDirtyOrder += 1
        }
    }

    private func coalesceSubtree(_ path: String, owner: URL) {
        var order = self.nextDirtyOrder
        for existing in self.dirtyPaths where existing == path || existing.hasPrefix(path + "/") {
            guard FileMetadataScanner.owner(of: URL(fileURLWithPath: existing), roots: self.activeRoots,
                                            exclusions: self.activeExclusions)?.path == owner.path else { continue }
            order = min(order, self.dirtyOrder[existing, default: order])
            self.dirtyPaths.remove(existing)
            self.dirtySubtrees.remove(existing)
            self.dirtyOrder.removeValue(forKey: existing)
        }
        self.insertDirty(path)
        self.dirtyOrder[path] = order
        self.dirtySubtrees.insert(path)
    }

    /// Scans one dirty directory under whichever active root claims it.
    /// Returns `true` to keep processing the remaining directories — whether
    /// this one was skipped (no root claims it) or scanned successfully —
    /// and `false` to abort the whole refresh, matching the original
    /// early-return behavior when the worker is cancelled or throws.
    private func refreshDirectory(_ directory: URL, index: FileNameIndex) async -> Bool {
        let roots = self.activeRoots
        let exclusions = self.activeExclusions
        let refresh = self.operations.refresh
        let worker = Task.detached(priority: .utility) {
            try await refresh(FileIndexRefreshRequest(
                path: directory, roots: roots, exclusions: exclusions, index: index
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
                let missed = (0 ..< count)
                    .contains {
                        flags[$0] &
                            UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped |
                                kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged |
                                kFSEventStreamEventFlagEventIdsWrapped) != 0
                    }
                if missed {
                    for root in service.activeRoots {
                        service.enqueueChange(root.path, subtree: true)
                    }
                }
                for (offset, path) in changed.enumerated() {
                    service.enqueueChange(path, subtree: flags[offset] & UInt32(kFSEventStreamEventFlagItemIsDir) != 0)
                }
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
