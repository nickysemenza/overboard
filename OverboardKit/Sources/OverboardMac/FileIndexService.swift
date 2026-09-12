import AppKit
import CoreServices
import Darwin
import Observation
import OverboardCore

/// Owns the OS-facing lifecycle. The database and ranking run on the core
/// actor; directory enumeration runs on a utility task and never reads bytes.
@MainActor
@Observable
public final class FileIndexService {
    public static let shared = FileIndexService()
    public private(set) var status = "File search hasn’t started"
    public private(set) var isIndexing = false
    public private(set) var fileCount = 0
    public private(set) var issues: [String] = []
    public var onChange: () -> Void = {}

    private var index: FileNameIndex?
    private var scanTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var eventStream: FSEventStreamRef?
    private var dirtyPaths = Set<String>()
    private var started = false
    private var activeRoots: [URL] = []
    private var activeExclusions: [String] = []

    private let rootsOverride: [URL]?
    private let exclusionsOverride: [String]?

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

    public static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        let providers = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        var roots = [home]
        if FileManager.default.fileExists(atPath: cloud.path) { roots.append(cloud) }
        if let children = try? FileManager.default.contentsOfDirectory(at: providers, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
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
        self.activeRoots = Array(Set(self.activeRoots.map(FileMetadataScanner.canonicalURL))).sorted { $0.path < $1.path }
        self.activeExclusions = self.exclusionsOverride ?? Defaults[.fileSearchExclusions].split(whereSeparator: \.isNewline).map(String.init)
        let roots = self.activeRoots
        let exclusions = self.activeExclusions
        self.scanTask = Task {
            await previousScan?.value
            await previousRefresh?.value
            guard !Task.isCancelled else { return }
            self.isIndexing = true
            do {
                if self.index == nil {
                    let directory = try OverboardDatabase.defaultDirectory()
                    self.index = try FileNameIndex(url: directory.appendingPathComponent("filenames.sqlite"))
                }
                guard let index = self.index else { return }
                if clear { try await index.reset() }
                try await index.retainRoots(roots.map(\.path))
                guard !Task.isCancelled else { return }
                self.watch(roots)
                self.fileCount = try await index.count()
                for root in roots {
                    guard !Task.isCancelled else { return }
                    self.status = "Indexing \(Self.locationName(root))…"
                    let generation = UUID().uuidString
                    let worker = Task.detached(priority: .utility) {
                        try await FileMetadataScanner.scan(root: root, exclusions: exclusions, generation: generation, index: index)
                    }
                    let failures = try await withTaskCancellationHandler {
                        try await worker.value
                    } onCancel: { worker.cancel() }
                    guard !Task.isCancelled else { return }
                    self.issues += failures
                    self.fileCount = try await index.count()
                    self.onChange()
                }
                self.isIndexing = false
                self.status = self.issues.isEmpty ? "\(self.fileCount.formatted()) files ready" : "\(self.fileCount.formatted()) files · some locations unavailable"
                self.onChange()
                if !self.dirtyPaths.isEmpty { self.scheduleRefresh() }
            } catch is CancellationError {
                // A successor owns the status.
            } catch {
                guard !Task.isCancelled else { return }
                self.isIndexing = false
                self.status = "File index unavailable. Rebuild in Settings → Files."
                self.issues = [error.localizedDescription]
                self.onChange()
            }
        }
    }

    public func results(for query: String) async -> [LauncherResult] {
        guard let index = self.index else { return [] }
        do { return try await index.search(query) } catch {
            self.status = "File search failed. Rebuild in Settings → Files."
            return []
        }
    }

    private func scheduleRefresh() {
        guard !self.isIndexing else { return }
        self.refreshTask?.cancel()
        self.refreshTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let index = self.index else { return }
            let changed = self.dirtyPaths.sorted { $0.count < $1.count }
            self.dirtyPaths.removeAll()
            var directories: [URL] = []
            for path in changed {
                let url = URL(fileURLWithPath: path)
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                let directory = isDirectory ? url : url.deletingLastPathComponent()
                if !directories.contains(where: { directory.path == $0.path || directory.path.hasPrefix($0.path + "/") }) {
                    directories.append(directory)
                }
            }
            self.isIndexing = true
            defer {
                self.isIndexing = false
                if !Task.isCancelled, !self.dirtyPaths.isEmpty { self.scheduleRefresh() }
            }
            for directory in directories {
                guard !Task.isCancelled else { return }
                guard let root = self.activeRoots.filter({ FileMetadataScanner.shouldInclude(directory, root: $0, exclusions: self.activeExclusions) }).max(by: { $0.path.count < $1.path.count }) else { continue }
                let exclusions = self.activeExclusions
                let worker = Task.detached(priority: .utility) {
                    try await FileMetadataScanner.scan(root: root, exclusions: exclusions, generation: UUID().uuidString, index: index, under: directory)
                }
                do {
                    let failures = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    guard !Task.isCancelled else { return }
                    self.issues = Array((self.issues + failures).suffix(12))
                } catch { return }
            }
            guard !Task.isCancelled else { return }
            self.fileCount = await (try? index.count()) ?? self.fileCount
            self.status = self.issues.isEmpty ? "\(self.fileCount.formatted()) files ready" : "\(self.fileCount.formatted()) files · some locations unavailable"
            self.onChange()
        }
    }

    private func watch(_ roots: [URL]) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        self.eventStream = FSEventStreamCreate(nil, { _, pointer, count, paths, flags, _ in
            guard let pointer else { return }
            // Stream is explicitly delivered on the main queue. Ignore our own
            // index/clipboard databases and excluded build trees to avoid loops.
            MainActor.assumeIsolated {
                let service = Unmanaged<FileIndexService>.fromOpaque(pointer).takeUnretainedValue()
                let changed = unsafeBitCast(paths, to: NSArray.self).compactMap { $0 as? String }
                let missed = (0 ..< count).contains { flags[$0] & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped) != 0 }
                if missed { service.dirtyPaths.formUnion(service.activeRoots.map(\.path)) }
                for path in changed where service.activeRoots.contains(where: { FileMetadataScanner.shouldInclude(URL(fileURLWithPath: path), root: $0, exclusions: service.activeExclusions) }) {
                    service.dirtyPaths.insert(path)
                }
                if !service.dirtyPaths.isEmpty { service.scheduleRefresh() }
            }
        }, &context, roots.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents))
        if let stream = self.eventStream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    private func stopWatching() {
        guard let stream = self.eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.eventStream = nil
    }

    public nonisolated static func locationName(_ root: URL) -> String {
        if root.path.contains("com~apple~CloudDocs") { return "iCloud Drive" }
        if root.path.contains("/CloudStorage/") { return root.lastPathComponent }
        if root == FileManager.default.homeDirectoryForCurrentUser { return "Home" }
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

public nonisolated enum FileMetadataScanner {
    /// Foundation deliberately abbreviates /private/var back to /var on some
    /// macOS releases. POSIX realpath agrees with enumerator/FSEvents paths.
    public static func canonicalURL(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url.standardized }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: url.hasDirectoryPath)
    }

    public static func shouldInclude(_ url: URL, root: URL, exclusions: [String]) -> Bool {
        // Use lexical normalization after canonicalizing roots. File-based
        // normalization rewrites /private/var only while a path exists, which
        // would discard the very FSEvents paths that report deleted files.
        let path = url.standardized.path
        let rootPath = root.standardized.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return false }
        let relative = String(path.dropFirst(rootPath.count)).split(separator: "/").map(String.init)
        // Cloud roots inside Library are scanned explicitly, not through Home.
        if root == FileManager.default.homeDirectoryForCurrentUser, relative.first == "Library" { return false }
        if relative.contains(where: { $0.hasPrefix(".") }) { return false }
        return !exclusions.contains { exclusion in
            let expanded = (exclusion.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") { return path == expanded || path.hasPrefix(expanded + "/") }
            return relative.contains(expanded)
        }
    }

    public static func scan(root: URL, exclusions: [String], generation: String, index: FileNameIndex, under directory: URL? = nil) async throws -> [String] {
        // Directory enumeration resolves aliases such as /var -> /private/var.
        // Roots and incremental scopes must use the same filesystem identity.
        let root = self.canonicalURL(root)
        let directory = directory.map(self.canonicalURL)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .contentModificationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        var failures: [String] = []
        guard let enumerator = FileManager.default.enumerator(at: directory ?? root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
            if failures.count < 12 { failures.append("\(url.path): \(error.localizedDescription)") }
            return true
        }) else { return ["\(root.path): Couldn’t read this location. Check access in System Settings."] }
        var batch: [IndexedFile] = []
        // An incremental enumeration yields descendants, not the directory
        // itself. Refresh its record before pruning the old generation.
        if let directory, directory != root,
           let values = try? directory.resourceValues(forKeys: keys)
        {
            batch.append(IndexedFile(path: directory.path, name: directory.lastPathComponent,
                                     root: root.path, generation: generation,
                                     modifiedAt: values.contentModificationDate ?? .distantPast,
                                     availability: FileAvailability.status(at: directory, values: values),
                                     isDirectory: true, location: FileIndexService.locationName(root)))
        }
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard self.shouldInclude(url, root: root, exclusions: exclusions) else {
                enumerator.skipDescendants()
                continue
            }
            do {
                let values = try url.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                if values.isPackage == true { enumerator.skipDescendants() }
                let availability = FileAvailability.status(at: url, values: values)
                batch.append(IndexedFile(path: url.path, name: url.lastPathComponent, root: root.path, generation: generation,
                                         modifiedAt: values.contentModificationDate ?? .distantPast, availability: availability,
                                         isDirectory: values.isDirectory == true, location: FileIndexService.locationName(root)))
            } catch {
                if failures.count < 12 { failures.append("\(url.path): \(error.localizedDescription)") }
            }
            if batch.count >= 400 {
                try await index.upsert(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()
        try await index.upsert(batch)
        try Task.checkCancellation()
        // Never erase known cloud/permission-denied entries after a partial scan.
        if failures.isEmpty { try await index.finishScan(root: root.path, generation: generation, under: directory?.path) }
        return failures
    }
}
