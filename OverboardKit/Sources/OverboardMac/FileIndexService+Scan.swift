import Darwin
import Foundation
import OverboardCore

public nonisolated enum FileMetadataScanner {
    /// Resource keys fetched for every entry, whether it's the incremental
    /// scan's own directory record or one yielded by the enumerator.
    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isPackageKey,
        .contentModificationDateKey,
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
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
        // Use lexical normalization after canonicalizing roots. File-based
        // normalization rewrites /private/var only while a path exists, which
        // would discard the very FSEvents paths that report deleted files.
        let path = url.standardized.path.precomposedStringWithCanonicalMapping
        let rootPath = root.standardized.path.precomposedStringWithCanonicalMapping
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return false }
        let relative = String(path.dropFirst(rootPath.count)).split(separator: "/").map(String.init)
        // Cloud roots inside Library are scanned explicitly, not through Home.
        if rootPath == self.canonicalURL(FileManager.default.homeDirectoryForCurrentUser).path,
           relative.first == "Library"
        {
            return false
        }
        if relative.contains(where: { $0.hasPrefix(".") }) {
            return false
        }
        return !exclusions.contains { exclusion in
            let expanded = (exclusion.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            guard !expanded.isEmpty else { return false }
            if expanded.hasPrefix("/") {
                let excluded = self.canonicalURL(URL(fileURLWithPath: expanded)).path
                return path == excluded || path.hasPrefix(excluded + "/")
            }
            return relative.contains(expanded)
        }
    }

    public static func owner(of url: URL, roots: [URL], exclusions: [String]) -> URL? {
        let path = url.standardized.path.precomposedStringWithCanonicalMapping
        guard let root = roots.filter({ path == $0.path || path.hasPrefix($0.path + "/") })
            .max(by: { $0.path.count < $1.path.count }),
            self.shouldInclude(url, root: root, exclusions: exclusions)
        else { return nil }
        return root
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
        index: FileNameIndex
    ) async throws -> [String] {
        try Task.checkCancellation()
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
            return try await self.scan(root: root, exclusions: exclusions, generation: UUID().uuidString,
                                       index: index, under: url, roots: roots)
        }
        if values.isPackage == true {
            try await index.remove(under: url.path)
        }
        try Task.checkCancellation()
        try await index.upsert([self.entry(url, values: values, root: root, generation: UUID().uuidString)])
        return []
    }

    private static func entry(_ url: URL, values: URLResourceValues, root: URL, generation: String) -> IndexedFile {
        IndexedFile(path: url.path, name: url.lastPathComponent, root: root.path, generation: generation,
                    modifiedAt: values.contentModificationDate ?? .distantPast,
                    availability: FileAvailability.status(at: url, values: values),
                    isDirectory: values.isDirectory == true, location: FileIndexService.locationName(root))
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
        let scope = directory ?? root
        guard self.owner(of: scope, roots: roots, exclusions: exclusions)?.path == root.path,
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
        let accumulator = ScanAccumulator()
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
                    root: root, roots: roots, exclusions: exclusions, generation: generation, index: index
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
        accumulator.batch.append(IndexedFile(
            path: directory.path,
            name: directory.lastPathComponent,
            root: root.path,
            generation: generation,
            modifiedAt: values.contentModificationDate ?? .distantPast,
            availability: FileAvailability.status(at: directory, values: values),
            isDirectory: true,
            location: FileIndexService.locationName(root)
        ))
    }

    /// Groups one scan invocation's fixed parameters so `indexEntries` stays
    /// under SwiftLint's parameter-count limit without losing readability.
    private struct ScanContext {
        let root: URL
        let roots: [URL]
        let exclusions: [String]
        let generation: String
        let index: FileNameIndex
    }

    /// The in-flight batch and failure list, shared by reference between
    /// `scan(...)`, its errorHandler closure, and `indexEntries` — see the
    /// exclusivity note at the `ScanAccumulator()` call site.
    private final class ScanAccumulator {
        var batch: [IndexedFile] = []
        var failures: [String] = []
    }

    /// Walks the enumerator to completion, classifying each entry and
    /// flushing to the index in batches. Split out of `scan(...)` so that
    /// function stays orchestration-only.
    private static func indexEntries(
        from enumerator: FileManager.DirectoryEnumerator,
        context: ScanContext,
        accumulator: ScanAccumulator
    ) async throws {
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard self.owner(of: url, roots: context.roots, exclusions: context.exclusions)?.path == context.root.path
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
                accumulator.batch.append(IndexedFile(
                    path: url.path,
                    name: url.lastPathComponent,
                    root: context.root.path,
                    generation: context.generation,
                    modifiedAt: values.contentModificationDate ?? .distantPast,
                    availability: FileAvailability.status(at: url, values: values),
                    isDirectory: values.isDirectory == true,
                    location: FileIndexService.locationName(context.root)
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
