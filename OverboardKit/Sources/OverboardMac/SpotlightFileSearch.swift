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
    private var activeObserver: NSObjectProtocol?
    private var activeContinuation: CheckedContinuation<[Hit], Never>?
    private var activeLimit = 0
    /// Distinguishes "this task's search" from a successor so a stale
    /// cancellation handler can't kill a newer query.
    private var generation = 0

    public init() {}

    public func search(_ term: String, limit: Int = 20) async -> [Hit] {
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
                query.predicate = NSPredicate(
                    format: "kMDItemFSName CONTAINS[cd] %@ OR kMDItemDisplayName CONTAINS[cd] %@",
                    term, term
                )
                query.searchScopes = [NSMetadataQueryUserHomeScope]
                query.sortDescriptors = [
                    NSSortDescriptor(key: NSMetadataItemLastUsedDateKey as String, ascending: false),
                ]

                self.activeQuery = query
                self.activeContinuation = continuation
                self.activeLimit = limit
                self.activeObserver = NotificationCenter.default.addObserver(
                    forName: .NSMetadataQueryDidFinishGathering,
                    object: query,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.finishActive()
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
        if let observer = activeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        query.stop()
        self.activeQuery = nil
        self.activeObserver = nil
        self.activeContinuation = nil
        self.activeLimit = 0
    }
}

/// Bridges Spotlight into the launcher's provider chain (the protocol lives
/// in OverboardCore, which can't see AppKit).
public struct FileSearchProvider: LauncherProvider {
    private let search: SpotlightFileSearch
    private let limit: Int

    public init(search: SpotlightFileSearch, limit: Int = 20) {
        self.search = search
        self.limit = limit
    }

    public func results(for query: String) async -> [LauncherResult] {
        guard query.count >= 2 else { return [] }
        let hits = await search.search(query, limit: self.limit)
        return hits.map { .file(name: $0.name, url: $0.url) }
    }
}
