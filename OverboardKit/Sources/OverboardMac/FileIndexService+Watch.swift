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
        self.pendingLossSince = nil
        let lifecycle = self.lifecycleGeneration
        self.isIndexing = true
        var completed = false
        defer {
            if self.lifecycleGeneration == lifecycle, !self.isStopped {
                self.isIndexing = false
                self.refreshTask = nil
                self.signalReconcile()
                if !Task.isCancelled, !self.dirtyPaths.isEmpty {
                    self.scheduleRefresh(delay: .seconds(1))
                }
                if completed {
                    self.checkpointProgressIfIdle()
                } else {
                    // `consumeDirtyChanges` already removed these paths, so an
                    // aborted pass has silently dropped work. Never record
                    // progress past it; a replay on next launch re-finds it.
                    self.isProgressBlocked = true
                }
            }
        }
        for directory in directories {
            guard !Task.isCancelled, await self.refreshDirectory(directory, index: index) else { return }
        }
        guard !Task.isCancelled else { return }
        let fileCount = await (try? index.count()) ?? self.fileCount
        guard !Task.isCancelled, self.lifecycleGeneration == lifecycle, !self.isStopped else { return }
        self.fileCount = fileCount
        self.status = Self.statusMessage(fileCount: self.fileCount, hasIssues: !self.issues.isEmpty)
        self.onChange()
        completed = true
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

    /// One FSEvents stream's configuration.
    nonisolated struct StreamPlan: Equatable, Sendable {
        var paths: [String]
        var exclusions: [String]
    }

    /// Splits roots into streams so `~/Library` can be excluded at the source.
    /// An exclusion applies to a whole stream, and the cloud roots live inside
    /// `~/Library`, so they get a stream of their own; every other root shares
    /// one stream that excludes `~/Library` (the bulk of the event volume:
    /// caches, Application Support, Biome). Exclusions must sit strictly inside
    /// a stream's roots, must not swallow one, and are capped at eight by
    /// FSEvents. The lexical prefilter still runs, so a refused exclusion costs
    /// only efficiency.
    ///
    /// `hidden` lists home's top-level dot-directories (`~/.cache`, agent
    /// worktrees, package caches). Nothing in them is indexed, but with file
    /// events their build churn alone can overflow the stream, which FSEvents
    /// answers with a `UserDropped` full rescan. They rank after `~/Library`
    /// and ahead of configured exclusions for the eight slots.
    nonisolated static func streamPlans(
        roots: [String], home: String, excluded: [String], hidden: [String] = []
    ) -> [StreamPlan] {
        let library = home + "/Library"
        let nested = roots.filter { $0.hasPrefix(library + "/") }
        let shared = roots.filter { !nested.contains($0) }
        func exclusions(for paths: [String], excludingLibrary: Bool) -> [String] {
            let candidates = (excludingLibrary ? [library] + hidden : []) + excluded
            var kept: [String] = []
            for candidate in candidates where !kept.contains(candidate) {
                let isInside = paths.contains { candidate.hasPrefix($0 + "/") }
                let swallowsRoot = paths.contains { $0 == candidate || $0.hasPrefix(candidate + "/") }
                if isInside, !swallowsRoot {
                    kept.append(candidate)
                }
            }
            return Array(kept.prefix(8))
        }
        var plans: [StreamPlan] = []
        if !shared.isEmpty {
            plans.append(StreamPlan(paths: shared, exclusions: exclusions(for: shared, excludingLibrary: true)))
        }
        if !nested.isEmpty {
            plans.append(StreamPlan(paths: nested, exclusions: exclusions(for: nested, excludingLibrary: false)))
        }
        return plans
    }

    /// Starts the streams. `since` replays history from a saved event ID; its
    /// end is signalled by `kFSEventStreamEventFlagHistoryDone`. Events are
    /// delivered on a private serial queue and filtered there, so the main
    /// actor hears about a callback only if something in it can matter.
    func watch(_ roots: [URL], since: UInt64? = nil) {
        let generation = self.lifecycleGeneration
        let sink = FileIndexEventSink(
            filter: FileIndexEventFilter(policy: self.pathPolicy), generation: generation
        ) { [weak self] batch, generation in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(batch, generation: generation) }
            }
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: FileIndexEventSink.retain,
            release: FileIndexEventSink.release,
            copyDescription: nil
        )
        let sinceWhen = since.map { FSEventStreamEventId($0) } ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        let plans = Self.streamPlans(
            roots: roots.map(\.path), home: self.pathPolicy.home, excluded: self.pathPolicy.excludedPaths,
            hidden: Self.hiddenDirectories(in: self.pathPolicy.home)
        )
        for plan in plans {
            guard let stream = FSEventStreamCreate(
                nil, FileIndexEventSink.callback, &context, plan.paths as CFArray, sinceWhen, 2,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot |
                    kFSEventStreamCreateFlagFileEvents)
            ) else { continue }
            if !plan.exclusions.isEmpty {
                _ = FSEventStreamSetExclusionPaths(stream, plan.exclusions as CFArray)
            }
            FSEventStreamSetDispatchQueue(stream, self.eventQueue)
            FSEventStreamStart(stream)
            self.eventStreams.append(stream)
            if since != nil {
                self.pendingHistoryStreams += 1
            }
        }
    }

    /// Top-level dot-directories of `home`, the known build and cache churners
    /// first so they win the scarce exclusion slots.
    nonisolated static func hiddenDirectories(in home: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        let hidden = names.filter { name in
            var isDirectory: ObjCBool = false
            return name.hasPrefix(".")
                && FileManager.default.fileExists(atPath: home + "/" + name, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        let busy = [".t3", ".cache", ".npm", ".cargo", ".rustup", ".nx", ".claude", ".bun", ".gradle", ".pnpm-store"]
        let ranked = busy.filter(hidden.contains) + hidden.filter { !busy.contains($0) }.sorted()
        return ranked.map { home + "/" + $0 }
    }

    func stopWatching() {
        for stream in self.eventStreams {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        self.eventStreams.removeAll()
        self.pendingHistoryStreams = 0
    }

    /// The main-actor half of the FSEvents callback: one call per callback,
    /// carrying only events the off-main filter could not rule out.
    func handle(_ batch: FileIndexEventBatch, generation: Int) {
        guard !self.isStopped, generation == self.lifecycleGeneration else { return }
        if batch.historyDone, self.pendingHistoryStreams > 0 {
            self.pendingHistoryStreams -= 1
        }
        if batch.lost {
            self.enqueueAllRoots()
            self.scheduleLossRecovery()
        } else {
            self.enqueueEvents(batch.paths, flags: batch.flags)
        }
        if self.dirtyPaths.isEmpty {
            self.checkpointProgressIfIdle()
        } else {
            self.scheduleRefresh()
        }
    }

    /// FSEvents drops events (`UserDropped`) during bursts such as a build,
    /// and the only safe recovery is rescanning every root, which for a home
    /// root is hundreds of thousands of entries. Drops arrive repeatedly while
    /// the burst lasts, so recovery waits for the stream to stay quiet: each
    /// drop pushes a not-yet-started refresh back by `lossQuietPeriod`, but
    /// never beyond `lossMaximumDelay` after the first drop, so a burst that
    /// never ends still gets its rescan.
    func scheduleLossRecovery(now: ContinuousClock.Instant = .now) {
        guard !self.isIndexing, !self.isStopped else { return }
        let firstLoss = self.pendingLossSince ?? now
        self.pendingLossSince = firstLoss
        let deadline = firstLoss + Self.lossMaximumDelay
        guard now < deadline else { return }
        self.refreshTask?.cancel()
        self.refreshTask = nil
        self.scheduleRefresh(delay: min(Self.lossQuietPeriod, deadline - now))
    }

    static let lossQuietPeriod: Duration = .seconds(30)
    static let lossMaximumDelay: Duration = .seconds(120)
}
