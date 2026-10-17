import Darwin
import Foundation
import OverboardCore

public nonisolated enum FileMetadataScanner {
    /// Foundation deliberately abbreviates /private/var back to /var on some
    /// macOS releases. POSIX realpath agrees with enumerator/FSEvents paths.
    public static func canonicalURL(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else {
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else { return url.standardizedFileURL }
            return self.canonicalURL(parent).appendingPathComponent(url.lastPathComponent,
                                                                    isDirectory: url.hasDirectoryPath)
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved).precomposedStringWithCanonicalMapping,
                   isDirectory: url.hasDirectoryPath)
    }

    public static func shouldInclude(_ url: URL, root: URL, exclusions: [String]) -> Bool {
        FileIndexPathPolicy(roots: [root.standardized], exclusions: exclusions).owner(of: url) != nil
    }

    public static func owner(of url: URL, roots: [URL], exclusions: [String]) -> URL? {
        FileIndexPathPolicy(roots: roots, exclusions: exclusions).owner(of: url)
    }

    /// Joins a directory path and an entry name without the doubled slash a
    /// naive join produces under `/`.
    static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    /// Whether `metadata` describes a package, which is indexed as one opaque
    /// entry and never descended into.
    static func isPackage(_ metadata: BulkEntry, classifier: PackageClassifier) -> Bool {
        metadata.isDirectory && classifier.isPackage(name: metadata.name, finderFlags: metadata.finderFlags)
    }

    private static func hasPackageAncestor(_ path: String, root: String, classifier: PackageClassifier) -> Bool {
        var parent = (path as NSString).deletingLastPathComponent
        while parent != root, parent.hasPrefix(root + "/") {
            if let metadata = try? BulkDirectoryWalker.stat(path: parent), self.isPackage(
                metadata,
                classifier: classifier
            ) {
                return true
            }
            parent = (parent as NSString).deletingLastPathComponent
        }
        return false
    }

    public static func refresh(
        _ url: URL,
        roots: [URL],
        exclusions: [String],
        index: FileNameIndex,
        scope: FileIndexRefreshScope = .subtree
    ) async throws -> [String] {
        try Task.checkCancellation()
        let canonicalRoots = roots.map(self.canonicalURL)
        // Resolve aliases in the parent, but leave the final component intact
        // so a symlink event cannot turn into an update of its target.
        let configuredRoot = zip(roots, canonicalRoots).first { $0.0.standardized.path == url.standardized.path }?.1
        let url = configuredRoot ?? self.canonicalURL(url.deletingLastPathComponent())
            .appendingPathComponent(url.lastPathComponent, isDirectory: url.hasDirectoryPath)
        let roots = canonicalRoots
        let classifier = PackageClassifier()
        guard let root = self.owner(of: url, roots: roots, exclusions: exclusions),
              !self.hasPackageAncestor(url.path, root: root.path, classifier: classifier)
        else {
            try await index.remove(under: url.path)
            return []
        }
        guard let metadata = try self.statOrNil(url.path), !metadata.isSymbolicLink else {
            try await index.remove(under: url.path)
            return []
        }
        let isPackage = self.isPackage(metadata, classifier: classifier)
        if metadata.isDirectory, !isPackage {
            switch scope {
            case .entry:
                if url.path == root.path {
                    return []
                }
            case .children:
                return try await self.refreshChildren(
                    url,
                    root: root,
                    roots: roots,
                    exclusions: exclusions,
                    index: index
                )
            case .subtree:
                return try await self.scan(root: root, exclusions: exclusions, generation: UUID().uuidString,
                                           index: index, under: url, roots: roots)
            }
        }
        if isPackage || !metadata.isDirectory {
            try await index.removeDescendants(under: url.path)
        }
        try Task.checkCancellation()
        let identity = EntryIdentity(root: root, generation: UUID().uuidString)
        try await index.upsert([self.entry(path: url.path, metadata: metadata, identity: identity)])
        return []
    }

    /// Metadata for `path`, or nil when it no longer exists.
    private static func statOrNil(_ path: String) throws -> BulkEntry? {
        do {
            return try BulkDirectoryWalker.stat(path: path)
        } catch where [ENOENT, ENOTDIR].contains(error.code) {
            return nil
        }
    }

    /// The per-scan facts every indexed entry shares. Resolving the location
    /// name and building the noise tracker once keeps both out of the loop.
    struct EntryIdentity {
        let rootPath: String
        let location: String
        let generation: String
        let noise: NoiseTracker

        init(root: URL, generation: String) {
            self.rootPath = root.path
            self.location = FileIndexService.locationName(root)
            self.generation = generation
            self.noise = NoiseTracker(root: root.path)
        }
    }

    static func entry(path: String, metadata: BulkEntry, identity: EntryIdentity) -> IndexedFile {
        IndexedFile(path: path, name: metadata.name, root: identity.rootPath, generation: identity.generation,
                    modifiedAt: metadata.modifiedAt, availability: metadata.availability,
                    isDirectory: metadata.isDirectory, location: identity.location,
                    isNoise: identity.noise.isNoise(path: path, isDirectory: metadata.isDirectory))
    }

    /// Whether the enumerator-equivalent rules index `metadata`: dot-files and
    /// `UF_HIDDEN` items are skipped (`.skipsHiddenFiles`) and symlinks are
    /// never indexed or followed.
    static func isIndexable(_ metadata: BulkEntry) -> Bool {
        !metadata.name.hasPrefix(".") && metadata.flags & UInt32(UF_HIDDEN) == 0 && !metadata.isSymbolicLink
    }

    public static func scan(
        root: URL,
        exclusions: [String],
        generation: String,
        index: FileNameIndex,
        under directory: URL? = nil,
        roots: [URL] = []
    ) async throws -> [String] {
        // Directory enumeration resolves aliases such as /var -> /private/var.
        // Roots and incremental scopes must use the same filesystem identity.
        let (root, directory) = (self.canonicalURL(root), directory.map(self.canonicalURL))
        let roots = roots.isEmpty ? [root] : roots.map(self.canonicalURL)
        let policy = FileIndexPathPolicy(roots: roots, exclusions: exclusions)
        let scope = directory ?? root
        let classifier = PackageClassifier()
        guard policy.owner(of: scope)?.path == root.path,
              !self.hasPackageAncestor(scope.path, root: root.path, classifier: classifier)
        else {
            try await index.remove(under: scope.path)
            return []
        }
        let scopeMetadata = try? BulkDirectoryWalker.stat(path: scope.path)
        if let scopeMetadata, self.isPackage(scopeMetadata, classifier: classifier) {
            return try await self.refresh(scope, roots: roots, exclusions: exclusions, index: index)
        }
        let identity = EntryIdentity(root: root, generation: generation)
        let accumulator = ScanAccumulator()
        try await index.beginScan(generation)

        do {
            // An incremental walk yields descendants, not the directory
            // itself. Refresh its record before reconciling the seen-path set.
            if let directory, directory != root, let scopeMetadata {
                accumulator.batch.append(self.entry(path: directory.path, metadata: scopeMetadata, identity: identity))
            }

            try await self.indexEntries(
                from: scope.path,
                context: ScanContext(
                    rootPath: root.path, policy: policy, identity: identity, index: index, classifier: classifier
                ),
                accumulator: accumulator
            )

            try Task.checkCancellation()
            try await index.upsert(accumulator.batch, seenIn: generation)
            try Task.checkCancellation()
            // Never erase known cloud/permission-denied entries after a partial scan.
            if accumulator.failures.isEmpty {
                try await index.finishScan(root: root.path, generation: generation, under: directory?.path)
            } else {
                try await index.discardScan(generation)
            }
            return accumulator.failures
        } catch {
            try? await index.discardScan(generation)
            throw error
        }
    }

    /// Groups one scan invocation's fixed parameters so `indexEntries` stays
    /// under SwiftLint's parameter-count limit without losing readability.
    private struct ScanContext {
        let rootPath: String
        let policy: FileIndexPathPolicy
        let identity: EntryIdentity
        let index: FileNameIndex
        let classifier: PackageClassifier
    }

    /// The in-flight batch and failure list for one scan.
    private final class ScanAccumulator {
        var batch: [IndexedFile] = []
        var failures: [String] = []
    }

    /// Walks `start` depth-first to completion, classifying each entry and
    /// flushing to the index in batches. Split out of `scan(...)` so that
    /// function stays orchestration-only.
    ///
    /// Paths are built by joining the canonical scope with names the kernel
    /// returned, so they are already canonical and need no `standardized` or
    /// `realpath` per entry.
    private static func indexEntries(
        from start: String,
        context: ScanContext,
        accumulator: ScanAccumulator
    ) async throws {
        var budget = FileIndexScanBudget()
        let walker = BulkDirectoryWalker()
        var pending = [start]
        while let directory = pending.popLast() {
            try Task.checkCancellation()
            let listing = walker.list(path: directory)
            if let error = listing.error, accumulator.failures.count < 12 {
                accumulator.failures.append("\(directory): \(error.message)")
            }
            for metadata in listing.entries {
                try Task.checkCancellation()
                try await budget.yieldIfNeeded()
                guard self.isIndexable(metadata) else { continue }
                let path = self.join(directory, metadata.name)
                guard context.policy.owner(ofPath: path)?.path == context.rootPath else { continue }
                if metadata.isDirectory, !self.isPackage(metadata, classifier: context.classifier) {
                    pending.append(path)
                }
                accumulator.batch.append(self.entry(path: path, metadata: metadata, identity: context.identity))
                if accumulator.batch.count >= 400 {
                    try await context.index.upsert(accumulator.batch, seenIn: context.identity.generation)
                    accumulator.batch.removeAll(keepingCapacity: true)
                }
            }
        }
    }
}
