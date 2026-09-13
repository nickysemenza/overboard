import CoreServices
import Foundation
import OverboardCore

/// FSEvents watching and the debounced incremental refresh it drives.
extension FileIndexService {
    func scheduleRefresh() {
        guard !self.isIndexing else { return }
        self.refreshTask?.cancel()
        self.refreshTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let index = self.index else { return }
            await self.performRefresh(index: index)
        }
    }

    /// Scans every dirty directory against the active roots, then folds the
    /// result into the published state. Runs on the debounce timer fired by
    /// `scheduleRefresh()`.
    private func performRefresh(index: FileNameIndex) async {
        let directories = self.consumeDirtyDirectories()
        self.isIndexing = true
        defer {
            self.isIndexing = false
            self.signalReconcile()
            if !Task.isCancelled, !self.dirtyPaths.isEmpty {
                self.scheduleRefresh()
            }
        }
        for directory in directories {
            guard !Task.isCancelled else { return }
            guard await self.refreshDirectory(directory, index: index) else { return }
        }
        guard !Task.isCancelled else { return }
        self.fileCount = await (try? index.count()) ?? self.fileCount
        self.status = Self.statusMessage(fileCount: self.fileCount, hasIssues: !self.issues.isEmpty)
        self.onChange()
    }

    /// Reduces the raw dirty paths to their containing directories, collapsing
    /// any directory whose parent is already in the set — a rescan of the
    /// parent covers it.
    private func consumeDirtyDirectories() -> [URL] {
        let changed = self.dirtyPaths.sorted { $0.count < $1.count }
        self.dirtyPaths.removeAll()
        var directories: [URL] = []
        for path in changed {
            let url = URL(fileURLWithPath: path)
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let directory = isDirectory ? url : url.deletingLastPathComponent()
            if !directories
                .contains(where: { directory.path == $0.path || directory.path.hasPrefix($0.path + "/") })
            {
                directories.append(directory)
            }
        }
        return directories
    }

    /// Scans one dirty directory under whichever active root claims it.
    /// Returns `true` to keep processing the remaining directories — whether
    /// this one was skipped (no root claims it) or scanned successfully —
    /// and `false` to abort the whole refresh, matching the original
    /// early-return behavior when the worker is cancelled or throws.
    private func refreshDirectory(_ directory: URL, index: FileNameIndex) async -> Bool {
        guard let root = self.activeRoots
            .filter({ FileMetadataScanner.shouldInclude(directory, root: $0, exclusions: self.activeExclusions) })
            .max(by: { $0.path.count < $1.path.count })
        else { return true }
        let exclusions = self.activeExclusions
        let worker = Task.detached(priority: .utility) {
            try await FileMetadataScanner.scan(
                root: root,
                exclusions: exclusions,
                generation: UUID().uuidString,
                index: index,
                under: directory
            )
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
                let changed = unsafeBitCast(paths, to: NSArray.self).compactMap { $0 as? String }
                let missed = (0 ..< count)
                    .contains {
                        flags[$0] &
                            UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped |
                                kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged |
                                kFSEventStreamEventFlagEventIdsWrapped) != 0
                    }
                if missed {
                    service.dirtyPaths.formUnion(service.activeRoots.map(\.path))
                }
                for path in changed where service.activeRoots.contains(where: { FileMetadataScanner.shouldInclude(
                    URL(fileURLWithPath: path),
                    root: $0,
                    exclusions: service.activeExclusions
                ) }) {
                    service.dirtyPaths.insert(path)
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
