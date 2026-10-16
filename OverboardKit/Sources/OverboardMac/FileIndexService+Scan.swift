import Darwin
import Foundation
import OverboardCore

public nonisolated enum FileMetadataScanner {
    /// Resource keys fetched for every entry, whether it's the incremental
    /// scan's own directory record or one yielded by the enumerator. Cloud
    /// download-state keys trigger provider round trips: use dataless flags
    /// for the cached badge, and recheck provider state at open time.
    static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isPackageKey,
        .contentModificationDateKey,
    ]

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

    private static func hasPackageAncestor(_ url: URL, root: URL) -> Bool {
        var parent = url.deletingLastPathComponent()
        while parent.path != root.path, parent.path.hasPrefix(root.path + "/") {
            if (try? parent.resourceValues(forKeys: [.isPackageKey]).isPackage) == true {
                return true
            }
            parent.deleteLastPathComponent()
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
        guard let root = self.owner(of: url, roots: roots, exclusions: exclusions),
              !self.hasPackageAncestor(url, root: root)
        else {
            try await index.remove(under: url.path)
            return []
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            try await index.remove(under: url.path)
            return []
        }
        let values = try url.resourceValues(forKeys: self.resourceKeys)
        if values.isSymbolicLink == true {
            try await index.remove(under: url.path)
            return []
        }
        if values.isDirectory == true, values.isPackage != true {
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
        if values.isPackage == true || values.isDirectory != true {
            try await index.removeDescendants(under: url.path)
        }
        try Task.checkCancellation()
        let entry = self.entry(url, values: values, root: root, generation: UUID().uuidString,
                               noise: NoiseTracker(root: root.path))
        try await index.upsert([entry])
        return []
    }

    static func entry(
        _ url: URL,
        values: URLResourceValues,
        root: URL,
        generation: String,
        noise: NoiseTracker
    ) -> IndexedFile {
        IndexedFile(path: url.path, name: url.lastPathComponent, root: root.path, generation: generation,
                    modifiedAt: values.contentModificationDate ?? .distantPast,
                    availability: FileAvailability.status(at: url, values: values),
                    isDirectory: values.isDirectory == true, location: FileIndexService.locationName(root),
                    isNoise: noise.isNoise(path: url.path, isDirectory: values.isDirectory == true))
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
        guard policy.owner(of: scope)?.path == root.path,
              !self.hasPackageAncestor(scope, root: root)
        else {
            try await index.remove(under: scope.path)
            return []
        }
        if let values = try? scope.resourceValues(forKeys: self.resourceKeys), values.isPackage == true {
            return try await self.refresh(scope, roots: roots, exclusions: exclusions, index: index)
        }
        // A reference type, not `inout` locals: the errorHandler closure below
        // escapes into the enumerator and keeps firing while `indexEntries` is
        // also mutating this state, and two `inout` borrows of the same local
        // across that overlap trip Swift's exclusivity checks at runtime.
        let accumulator = ScanAccumulator(noise: NoiseTracker(root: root.path))
        try await index.beginScan(generation)
        guard let enumerator = self.enumerator(at: directory ?? root, accumulator: accumulator) else {
            try await index.discardScan(generation)
            return ["\(root.path): Couldn’t read this location. Check access in System Settings."]
        }

        do {
            self.appendDirectoryEntry(directory, root: root, generation: generation, accumulator: accumulator)

            try await self.indexEntries(
                from: enumerator,
                context: ScanContext(
                    root: root, policy: policy, generation: generation, index: index
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

    private static func enumerator(
        at directory: URL,
        accumulator: ScanAccumulator
    ) -> FileManager.DirectoryEnumerator? {
        FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(self.resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                if accumulator.failures.count < 12 {
                    accumulator.failures.append("\(url.path): \(error.localizedDescription)")
                }
                return true
            }
        )
    }

    private static func appendDirectoryEntry(
        _ directory: URL?,
        root: URL,
        generation: String,
        accumulator: ScanAccumulator
    ) {
        // An incremental enumeration yields descendants, not the directory
        // itself. Refresh its record before reconciling the seen-path set.
        guard let directory, directory != root,
              let values = try? directory.resourceValues(forKeys: self.resourceKeys)
        else { return }
        accumulator.batch.append(self.entry(
            directory, values: values, root: root, generation: generation, noise: accumulator.noise
        ))
    }

    /// Groups one scan invocation's fixed parameters so `indexEntries` stays
    /// under SwiftLint's parameter-count limit without losing readability.
    private struct ScanContext {
        let root: URL
        let policy: FileIndexPathPolicy
        let generation: String
        let index: FileNameIndex
    }

    /// The in-flight batch and failure list, shared by reference between
    /// `scan(...)`, its errorHandler closure, and `indexEntries` — see the
    /// exclusivity note at the `ScanAccumulator()` call site.
    private final class ScanAccumulator {
        var batch: [IndexedFile] = []
        var failures: [String] = []
        let noise: NoiseTracker

        init(noise: NoiseTracker) {
            self.noise = noise
        }
    }

    /// Walks the enumerator to completion, classifying each entry and
    /// flushing to the index in batches. Split out of `scan(...)` so that
    /// function stays orchestration-only.
    private static func indexEntries(
        from enumerator: FileManager.DirectoryEnumerator,
        context: ScanContext,
        accumulator: ScanAccumulator
    ) async throws {
        var budget = FileIndexScanBudget()
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            try await budget.yieldIfNeeded()
            guard context.policy.owner(of: url)?.path == context.root.path
            else {
                enumerator.skipDescendants()
                continue
            }
            do {
                let values = try url.resourceValues(forKeys: self.resourceKeys)
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants(); continue
                }
                if values.isPackage == true {
                    enumerator.skipDescendants()
                }
                accumulator.batch.append(self.entry(
                    url, values: values, root: context.root, generation: context.generation,
                    noise: accumulator.noise
                ))
            } catch {
                if accumulator.failures.count < 12 {
                    accumulator.failures.append("\(url.path): \(error.localizedDescription)")
                }
            }
            if accumulator.batch.count >= 400 {
                try await context.index.upsert(accumulator.batch, seenIn: context.generation)
                accumulator.batch.removeAll(keepingCapacity: true)
            }
        }
    }
}
