import Foundation
import OverboardCore

extension FileMetadataScanner {
    /// Reconciles one level, preserving known child-directory subtrees. A
    /// newly discovered directory still needs a recursive discovery pass.
    static func refreshChildren(_ directory: URL, root: URL, roots: [URL], exclusions: [String],
                                index: FileNameIndex) async throws -> [String]
    {
        let previous = try await index.children(under: directory.path, root: root.path)
        let state = ChildrenScanState()
        let context = ChildrenScanContext(root: root, roots: roots, exclusions: exclusions, index: index,
                                          known: Dictionary(uniqueKeysWithValues: previous.map { ($0.path, $0) }))
        var budget = FileIndexScanBudget()
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: Array(self.resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants],
            errorHandler: { url, error in
                state.record("\(url.path): \(error.localizedDescription)")
                return true
            }
        ) else { return ["\(directory.path): Couldn’t read this location. Check access in System Settings."] }

        if directory.path != root.path, let values = try? directory.resourceValues(forKeys: self.resourceKeys) {
            state.batch.append(self.entry(
                directory,
                values: values,
                root: root,
                generation: context.generation,
                noise: context.noise
            ))
        }
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            try await budget.yieldIfNeeded()
            try await self.refreshChild(url, context: context, state: state)
            if state.batch.count >= 400 {
                try await index.upsert(state.batch)
                state.batch.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()
        try await index.upsert(state.batch)
        // Enumeration/access failures cannot be interpreted as deletions.
        if state.failures.isEmpty {
            for child in previous where !state.seen.contains(child.path) {
                try Task.checkCancellation()
                try await index.remove(under: child.path)
            }
        }
        return state.failures
    }

    private static func refreshChild(_ url: URL, context: ChildrenScanContext,
                                     state: ChildrenScanState) async throws
    {
        guard context.policy.owner(of: url)?.path == context.root.path else { return }
        do {
            let values = try url.resourceValues(forKeys: self.resourceKeys)
            guard values.isSymbolicLink != true else { return }
            let path = url.path.precomposedStringWithCanonicalMapping
            state.seen.insert(path)
            if values.isDirectory == true, values.isPackage != true {
                if context.known[path]?.isDirectory != true {
                    let failures = try await self.scan(root: context.root, exclusions: context.exclusions,
                                                       generation: context.generation, index: context.index,
                                                       under: url, roots: context.roots)
                    for failure in failures {
                        state.record(failure)
                    }
                }
            } else if context.known[path]?.isDirectory == true {
                try await context.index.removeDescendants(under: path)
            }
            state.batch.append(self.entry(url, values: values, root: context.root, generation: context.generation,
                                          noise: context.noise))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            state.record("\(url.path): \(error.localizedDescription)")
        }
    }
}

private final nonisolated class ChildrenScanState {
    var seen = Set<String>()
    var batch: [IndexedFile] = []
    var failures: [String] = []

    func record(_ failure: String) {
        if self.failures.count < 12 {
            self.failures.append(failure)
        }
    }
}

private nonisolated struct ChildrenScanContext {
    let root: URL
    let roots: [URL]
    let exclusions: [String]
    let index: FileNameIndex
    let known: [String: IndexedFile]
    let generation = UUID().uuidString
    let policy: FileIndexPathPolicy
    let noise: NoiseTracker

    init(root: URL, roots: [URL], exclusions: [String], index: FileNameIndex, known: [String: IndexedFile]) {
        self.root = root
        self.roots = roots
        self.exclusions = exclusions
        self.index = index
        self.known = known
        self.policy = FileIndexPathPolicy(roots: roots, exclusions: exclusions)
        self.noise = NoiseTracker(root: root.path)
    }
}
