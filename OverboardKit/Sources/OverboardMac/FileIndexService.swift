import AppKit
import CoreServices
import Observation
import OverboardCore

/// One line of `FileIndexService.issues`, split into the location it names and
/// the reason. The scanner formats failures as "<path>: <reason>" (a bare
/// message when the failure isn't about one path), which is fine to read but
/// not enough to act on — parsing it back gives Settings → Permissions a folder
/// to reveal.
public nonisolated struct FileIndexIssue: Identifiable, Sendable, Equatable {
    /// The raw line, which is unique enough to identify a row.
    public let id: String
    public let url: URL?
    public let message: String

    public init(raw: String) {
        self.id = raw
        // Only an absolute path is a location we can act on; anything else is
        // a whole-index failure whose text is already the whole message.
        guard raw.hasPrefix("/"), let separator = raw.range(of: ": ") else {
            self.url = nil
            self.message = raw
            return
        }
        self.url = URL(fileURLWithPath: String(raw[raw.startIndex ..< separator.lowerBound]))
        self.message = String(raw[separator.upperBound...])
    }

    /// Shows the folder in Finder. A no-op when the issue names no path, or
    /// when the path is gone — which is itself an answer.
    @MainActor
    public func revealInFinder() {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Owns the OS-facing lifecycle. The database and ranking run on the core
/// actor; directory enumeration runs on a utility task and never reads bytes.
///
/// Split across extensions in this directory: this file owns the scan
/// lifecycle (`start`/`rebuild`), `FileIndexService+Watch.swift` owns FSEvents
/// watching and the incremental refresh it triggers, and
/// `FileIndexService+Scan.swift` holds the standalone `FileMetadataScanner`
/// that both call into.
@MainActor
@Observable
public final class FileIndexService {
    public static let shared = FileIndexService()
    public internal(set) var status = "File search hasn’t started"
    public internal(set) var isIndexing = false
    public internal(set) var fileCount = 0
    public internal(set) var issues: [String] = []
    public var onChange: () -> Void = {}

    var index: FileNameIndex?
    private var scanTask: Task<Void, Never>?
    var refreshTask: Task<Void, Never>?
    var eventStream: FSEventStreamRef?
    var dirtyPaths = Set<String>()
    private var started = false
    var activeRoots: [URL] = []
    var activeExclusions: [String] = []

    private let rootsOverride: [URL]?
    private let exclusionsOverride: [String]?
    /// Callers parked in ``nextReconcile()``, resumed by ``signalReconcile()``
    /// or, one at a time, by cancellation — hence keyed rather than a list.
    private var reconcileWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init(index: FileNameIndex? = nil, roots: [URL]? = nil, exclusions: [String]? = nil) {
        self.index = index
        self.rootsOverride = roots
        self.exclusionsOverride = exclusions
    }

    isolated deinit {
        self.scanTask?.cancel()
        self.refreshTask?.cancel()
        self.stopWatching()
    }

    /// Tears down the FSEvents stream and cancels in-flight scan/refresh work.
    /// `shared` is a singleton that otherwise only stops via `deinit`, which a
    /// process `exit()` never runs — called explicitly from app shutdown
    /// (`AppServices.stop()`) so the stream doesn't survive to `exit()`.
    public func stop() {
        self.scanTask?.cancel()
        self.refreshTask?.cancel()
        self.stopWatching()
    }

    public static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        let providers = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        var roots = [home]
        if FileManager.default.fileExists(atPath: cloud.path) {
            roots.append(cloud)
        }
        if let children = try? FileManager.default.contentsOfDirectory(
            at: providers,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            roots += children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        return roots
    }

    public func start() {
        guard !self.started else { return }
        self.started = true
        self.rebuild(clear: false)
    }

    public func rebuild(clear: Bool = true) {
        let previousScan = self.scanTask
        let previousRefresh = self.refreshTask
        previousScan?.cancel()
        previousRefresh?.cancel()
        self.stopWatching()
        self.issues = []
        self.isIndexing = true
        self.status = "Preparing file search…"
        let configured = self.rootsOverride?.map(\.path) ?? Defaults[.fileSearchRoots]
        self.activeRoots = configured.isEmpty ? Self.defaultRoots : configured.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        self.activeRoots = Array(Set(self.activeRoots.map(FileMetadataScanner.canonicalURL)))
            .sorted { $0.path < $1.path }
        self.activeExclusions = self.exclusionsOverride ?? Defaults[.fileSearchExclusions]
            .split(whereSeparator: \.isNewline).map(String.init)
        let roots = self.activeRoots
        let exclusions = self.activeExclusions
        self.scanTask = Task {
            await previousScan?.value
            await previousRefresh?.value
            guard !Task.isCancelled else { return }
            do {
                try await self.runScan(roots: roots, exclusions: exclusions, clear: clear)
            } catch is CancellationError {
                // A successor owns the status.
            } catch {
                guard !Task.isCancelled else { return }
                self.isIndexing = false
                self.status = "File index unavailable. Rebuild in Settings → Files."
                self.issues = [error.localizedDescription]
                self.onChange()
                self.signalReconcile()
            }
        }
    }

    /// The full-index pass driven by `rebuild()`: opens/prepares the index,
    /// starts watching, then scans each root in turn.
    private func runScan(roots: [URL], exclusions: [String], clear: Bool) async throws {
        self.isIndexing = true
        if self.index == nil {
            let directory = try OverboardDatabase.defaultDirectory()
            self.index = try FileNameIndex(url: directory.appendingPathComponent("filenames.sqlite"))
        }
        guard let index = self.index else { return }
        if clear {
            try await index.reset()
        }
        try await index.retainRoots(roots.map(\.path))
        guard !Task.isCancelled else { return }
        self.watch(roots)
        self.fileCount = try await index.count()
        for root in roots {
            try await self.scanRoot(root, exclusions: exclusions, index: index)
            guard !Task.isCancelled else { return }
        }
        self.isIndexing = false
        self.status = Self.statusMessage(fileCount: self.fileCount, hasIssues: !self.issues.isEmpty)
        self.onChange()
        self.signalReconcile()
        if !self.dirtyPaths.isEmpty {
            self.scheduleRefresh()
        }
    }

    /// Scans a single root and folds its failures/count into the published state.
    private func scanRoot(_ root: URL, exclusions: [String], index: FileNameIndex) async throws {
        guard !Task.isCancelled else { return }
        self.status = "Indexing \(Self.locationName(root))…"
        let generation = UUID().uuidString
        let worker = Task.detached(priority: .utility) {
            try await FileMetadataScanner.scan(
                root: root,
                exclusions: exclusions,
                generation: generation,
                index: index
            )
        }
        let failures = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return }
        self.issues += failures
        self.fileCount = try await index.count()
        self.onChange()
    }

    /// Returns when the next index pass finishes — the initial scan, or a
    /// reconcile triggered by filesystem events.
    ///
    /// FSEvents delivery and the refresh debounce are genuinely asynchronous,
    /// so a test can't avoid waiting; what it *can* avoid is guessing how long
    /// to wait. Parking on this instead of polling `isIndexing` on a sleep loop
    /// means a test wakes exactly when the index is consistent again. Park
    /// before making the change you want reconciled: everything here is
    /// main-actor, so a `FileManager` call followed by `await nextReconcile()`
    /// can't miss the signal. A pass abandoned by cancellation signals nothing,
    /// since its successor owns the outcome.
    public func nextReconcile() async {
        let id = UUID()
        // Cancellable on purpose: a caller that races this against a deadline
        // (or is torn down) would otherwise leave a continuation parked here
        // forever, and its task group would wait on that child for good.
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    self.reconcileWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.resumeReconcileWaiter(id) }
        }
    }

    private func resumeReconcileWaiter(_ id: UUID) {
        self.reconcileWaiters.removeValue(forKey: id)?.resume()
    }

    func signalReconcile() {
        let waiters = self.reconcileWaiters
        self.reconcileWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume()
        }
    }

    public func results(for query: String) async -> [LauncherResult] {
        guard let index = self.index else { return [] }
        do { return try await index.search(query) } catch {
            self.status = "File search failed. Rebuild in Settings → Files."
            return []
        }
    }

    static func statusMessage(fileCount: Int, hasIssues: Bool) -> String {
        hasIssues
            ? "\(fileCount.formatted()) files · some locations unavailable"
            : "\(fileCount.formatted()) files ready"
    }

    public nonisolated static func locationName(_ root: URL) -> String {
        if root.path.contains("com~apple~CloudDocs") {
            return "iCloud Drive"
        }
        if root.path.contains("/CloudStorage/") {
            return root.lastPathComponent
        }
        if root == FileManager.default.homeDirectoryForCurrentUser {
            return "Home"
        }
        return root.lastPathComponent
    }
}

public struct IndexedFileSearchProvider: LauncherProvider {
    public var searchScopes: Set<LauncherScope> {
        [.all, .files]
    }

    private let service: FileIndexService

    public init(service: FileIndexService) {
        self.service = service
    }

    public func results(for query: String) async -> [LauncherResult] {
        await self.service.results(for: query)
    }
}
