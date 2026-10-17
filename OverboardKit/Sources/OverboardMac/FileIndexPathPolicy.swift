import Foundation

/// Resolves filesystem identities once per configuration, then uses lexical
/// comparisons even for deleted paths. No realpath calls in the entry loop.
nonisolated struct FileIndexPathPolicy: Sendable {
    private let roots: [URL]
    private let home: String
    private let excludedPaths: [String]
    private let excludedNames: Set<String>

    init(roots: [URL], exclusions: [String]) {
        self.roots = roots.sorted { $0.path.count > $1.path.count }
        self.home = FileMetadataScanner.canonicalURL(FileManager.default.homeDirectoryForCurrentUser).path
        var paths: [String] = []
        var names = Set<String>()
        for exclusion in exclusions {
            let expanded = (exclusion.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            guard !expanded.isEmpty else { continue }
            if expanded.hasPrefix("/") {
                paths.append(FileMetadataScanner.canonicalURL(URL(fileURLWithPath: expanded)).path)
            } else {
                names.insert(expanded)
            }
        }
        self.excludedPaths = paths
        self.excludedNames = names
    }

    func owner(of url: URL) -> URL? {
        self.owner(ofPath: url.standardized.path)
    }

    /// For paths already canonical, such as a canonical root joined with names
    /// a directory read returned: skips `URL.standardized` per entry.
    func owner(ofPath rawPath: String) -> URL? {
        // Pure-ASCII paths are already precomposed; avoid the bridged call.
        let path = rawPath.utf8.allSatisfy { $0 < 0x80 } ? rawPath : rawPath.precomposedStringWithCanonicalMapping
        guard let root = self.roots.first(where: { path == $0.path || path.hasPrefix($0.path + "/") })
        else { return nil }
        let relative = path.dropFirst(root.path.count).split(separator: "/")
        if root.path == self.home, relative.first == "Library" {
            return nil
        }
        if relative.contains(where: { $0.hasPrefix(".") || self.excludedNames.contains(String($0)) }) {
            return nil
        }
        if self.excludedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return nil
        }
        return root
    }
}
