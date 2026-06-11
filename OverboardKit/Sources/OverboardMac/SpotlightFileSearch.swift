import AppKit
import OverboardCore

/// One-shot Spotlight lookups for the launcher. NSMetadataQuery is
/// runloop-coupled, so the whole type is main-actor; each new search (or
/// task cancellation) stops the previous query and resumes it with [].
/// Live updates are never enabled — one query per (debounced) keystroke.
@MainActor
public final class SpotlightFileSearch {
    public struct Hit: Sendable, Equatable {
        public let name: String
        public let url: URL

        public init(name: String, url: URL) {
            self.name = name
            self.url = url
        }
    }

    private var activeQuery: NSMetadataQuery?
    private var activeObservers: [NSObjectProtocol] = []
    private var activeContinuation: CheckedContinuation<[Hit], Never>?
    private var activeLimit = 0
    private var timeoutTask: Task<Void, Never>?
    private var deadlinePassed = false
    /// Distinguishes "this task's search" from a successor so a stale
    /// cancellation handler can't kill a newer query.
    private var generation = 0

    /// mds can take seconds to declare gathering *finished* even though the
    /// hits arrive almost immediately. Past this deadline we ship as soon as
    /// we have *any* hits (at the deadline if some already gathered, else on
    /// the next progress tick). Queries with no hits yet keep waiting for
    /// finish-gathering so slow gathers still surface results eventually.
    private let harvestDeadline: Duration = .milliseconds(700)

    public init() {}

    /// General files anywhere in the user's home folder.
    public func search(_ term: String, limit: Int = 20) async -> [Hit] {
        await self.run(
            predicate: NSPredicate(
                format: "kMDItemFSName CONTAINS[cd] %@ OR kMDItemDisplayName CONTAINS[cd] %@",
                term, term
            ),
            scopes: [NSMetadataQueryUserHomeScope],
            limit: limit
        )
    }

    private func run(predicate: NSPredicate, scopes: [Any], limit: Int) async -> [Hit] {
        self.cancelActive()
        self.generation += 1
        let myGeneration = self.generation

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: [])
                    return
                }

                let query = NSMetadataQuery()
                query.predicate = predicate
                query.searchScopes = scopes
                query.sortDescriptors = [
                    NSSortDescriptor(key: NSMetadataItemLastUsedDateKey as String, ascending: false),
                ]

                self.activeQuery = query
                self.activeContinuation = continuation
                self.activeLimit = limit

                // Three harvest triggers, first one wins: gathering finished,
                // enough rows mid-gather, or the deadline.
                self.activeObservers = [
                    NotificationCenter.default.addObserver(
                        forName: .NSMetadataQueryDidFinishGathering,
                        object: query,
                        queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.finishActive()
                        }
                    },
                    NotificationCenter.default.addObserver(
                        forName: .NSMetadataQueryGatheringProgress,
                        object: query,
                        queue: .main
                    ) { [weak self] _ in
                        // Registered per-query and removed at teardown, so
                        // activeQuery is necessarily the query that fired.
                        MainActor.assumeIsolated {
                            guard let self, let active = self.activeQuery else { return }
                            let enough = active.resultCount >= limit
                            let lateButSomething = self.deadlinePassed && active.resultCount > 0
                            if enough || lateButSomething {
                                self.finishActive()
                            }
                        }
                    },
                ]
                self.timeoutTask = Task { [weak self, harvestDeadline] in
                    try? await Task.sleep(for: harvestDeadline)
                    guard !Task.isCancelled, let self,
                          self.generation == myGeneration, let active = self.activeQuery else { return }
                    self.deadlinePassed = true
                    if active.resultCount > 0 {
                        self.finishActive()
                    }
                }

                if !query.start() {
                    self.cancelActive()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == myGeneration else { return }
                self.cancelActive()
            }
        }
    }

    /// Reads at most `activeLimit` paths (per-item attribute access is the
    /// slow part), then tears the query down. Must read before stop().
    private func finishActive() {
        guard let query = activeQuery, let continuation = activeContinuation else { return }
        query.disableUpdates()

        var hits: [Hit] = []
        for index in 0 ..< min(query.resultCount, self.activeLimit) {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey as String) as? String
            else { continue }
            let url = URL(fileURLWithPath: path)
            let name = item.value(forAttribute: NSMetadataItemDisplayNameKey as String) as? String
            hits.append(Hit(name: name ?? url.lastPathComponent, url: url))
        }

        self.tearDown(query)
        continuation.resume(returning: hits)
    }

    private func cancelActive() {
        guard let query = activeQuery else { return }
        let continuation = self.activeContinuation
        self.tearDown(query)
        continuation?.resume(returning: [])
    }

    /// Clears state *before* the continuation resumes so a re-entrant
    /// search can't see a half-torn-down query.
    private func tearDown(_ query: NSMetadataQuery) {
        for observer in self.activeObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        self.timeoutTask?.cancel()
        query.stop()
        self.activeQuery = nil
        self.activeObservers = []
        self.activeContinuation = nil
        self.activeLimit = 0
        self.timeoutTask = nil
        self.deadlinePassed = false
    }
}

/// Bridges Spotlight into the launcher's provider chain (the protocol lives
/// in OverboardCore, which can't see AppKit). Each provider owns its own
/// SpotlightFileSearch — one instance can only run one query at a time.
public struct FileSearchProvider: LauncherProvider {
    private let search: SpotlightFileSearch
    private let limit: Int

    public init(search: SpotlightFileSearch, limit: Int = 20) {
        self.search = search
        self.limit = limit
    }

    public func results(for query: String) async -> [LauncherResult] {
        guard query.count >= 2 else { return [] }
        // Over-fetch: FileNameMatcher drops mid-word junk, which would
        // otherwise starve the row list.
        let hits = await search.search(query, limit: self.limit * 2)
        return hits
            .enumerated()
            .compactMap { index, hit in
                FileNameMatcher.rank(name: hit.name, query: query)
                    .map { (rank: $0, index: index, hit: hit) }
            }
            // Index tiebreaker keeps Spotlight's recency order within a tier
            // (Swift's sort is not guaranteed stable).
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .prefix(self.limit)
            .map { .file(name: $0.hit.name, url: $0.hit.url) }
    }
}
