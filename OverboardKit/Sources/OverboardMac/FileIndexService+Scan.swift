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
        if root == FileManager.default.homeDirectoryForCurrentUser, relative.first == "Library" {
            return false
        }
        if relative.contains(where: { $0.hasPrefix(".") }) {
            return false
        }
        return !exclusions.contains { exclusion in
            let expanded = (exclusion.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                return path == expanded || path.hasPrefix(expanded + "/")
            }
            return relative.contains(expanded)
        }
    }

    public static func scan(
        root: URL,
        exclusions: [String],
        generation: String,
        index: FileNameIndex,
        under directory: URL? = nil
    ) async throws -> [String] {
        // Directory enumeration resolves aliases such as /var -> /private/var.
        // Roots and incremental scopes must use the same filesystem identity.
        let root = self.canonicalURL(root)
        let directory = directory.map(self.canonicalURL)
        var failures: [String] = []
        guard let enumerator = FileManager.default.enumerator(
            at: directory ?? root,
            includingPropertiesForKeys: Array(self.resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                if failures.count < 12 {
                    failures.append("\(url.path): \(error.localizedDescription)")
                }
                return true
            }
        ) else { return ["\(root.path): Couldn’t read this location. Check access in System Settings."] }

        var batch: [IndexedFile] = []
        // An incremental enumeration yields descendants, not the directory
        // itself. Refresh its record before pruning the old generation.
        if let directory, directory != root,
           let values = try? directory.resourceValues(forKeys: self.resourceKeys)
        {
            batch.append(IndexedFile(path: directory.path, name: directory.lastPathComponent,
                                     root: root.path, generation: generation,
                                     modifiedAt: values.contentModificationDate ?? .distantPast,
                                     availability: FileAvailability.status(at: directory, values: values),
                                     isDirectory: true, location: FileIndexService.locationName(root)))
        }

        try await self.indexEntries(
            from: enumerator,
            context: ScanContext(root: root, exclusions: exclusions, generation: generation, index: index),
            batch: &batch,
            failures: &failures
        )

        try Task.checkCancellation()
        try await index.upsert(batch)
        try Task.checkCancellation()
        // Never erase known cloud/permission-denied entries after a partial scan.
        if failures.isEmpty {
            try await index.finishScan(root: root.path, generation: generation, under: directory?.path)
        }
        return failures
    }

    /// Groups one scan invocation's fixed parameters so `indexEntries` stays
    /// under SwiftLint's parameter-count limit without losing readability.
    private struct ScanContext {
        let root: URL
        let exclusions: [String]
        let generation: String
        let index: FileNameIndex
    }

    /// Walks the enumerator to completion, classifying each entry and
    /// flushing to the index in batches. Split out of `scan(...)` so that
    /// function stays orchestration-only.
    private static func indexEntries(
        from enumerator: FileManager.DirectoryEnumerator,
        context: ScanContext,
        batch: inout [IndexedFile],
        failures: inout [String]
    ) async throws {
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard self.shouldInclude(url, root: context.root, exclusions: context.exclusions) else {
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
                batch.append(IndexedFile(
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
                if failures.count < 12 {
                    failures.append("\(url.path): \(error.localizedDescription)")
                }
            }
            if batch.count >= 400 {
                try await context.index.upsert(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
    }
}
