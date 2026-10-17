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

        if directory.path != root.path,
           let metadata = try? BulkDirectoryWalker.stat(path: directory.path)
        {
            state.batch.append(self.entry(path: directory.path, metadata: metadata, identity: context.identity))
        }
        let listing = BulkDirectoryWalker().list(path: directory.path)
        if let error = listing.error {
            state.record("\(directory.path): \(error.message)")
        }
        for metadata in listing.entries {
            try Task.checkCancellation()
            try await budget.yieldIfNeeded()
            try await self.refreshChild(metadata, in: directory.path, context: context, state: state)
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

    private static func refreshChild(_ metadata: BulkEntry, in directory: String, context: ChildrenScanContext,
                                     state: ChildrenScanState) async throws
    {
        guard self.isIndexable(metadata) else { return }
        let path = self.join(directory, metadata.name)
        guard context.policy.owner(ofPath: path)?.path == context.root.path else { return }
        // NFD names from the kernel must compare equal to the precomposed
        // paths the index stores.
        let canonicalPath = path.precomposedStringWithCanonicalMapping
        state.seen.insert(canonicalPath)
        if metadata.isDirectory, !self.isPackage(metadata, classifier: context.classifier) {
            if context.known[canonicalPath]?.isDirectory != true {
                let failures = try await self.scan(root: context.root, exclusions: context.exclusions,
                                                   generation: context.identity.generation, index: context.index,
                                                   under: URL(fileURLWithPath: path, isDirectory: true),
                                                   roots: context.roots)
                for failure in failures {
                    state.record(failure)
                }
            }
        } else if context.known[canonicalPath]?.isDirectory == true {
            try await context.index.removeDescendants(under: canonicalPath)
        }
        state.batch.append(self.entry(path: path, metadata: metadata, identity: context.identity))
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
    let policy: FileIndexPathPolicy
    let identity: FileMetadataScanner.EntryIdentity
    let classifier = PackageClassifier()

    init(root: URL, roots: [URL], exclusions: [String], index: FileNameIndex, known: [String: IndexedFile]) {
        self.root = root
        self.roots = roots
        self.exclusions = exclusions
        self.index = index
        self.known = known
        self.policy = FileIndexPathPolicy(roots: roots, exclusions: exclusions)
        self.identity = FileMetadataScanner.EntryIdentity(root: root, generation: UUID().uuidString)
    }
}
