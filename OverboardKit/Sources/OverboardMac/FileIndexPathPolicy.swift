import Foundation

/// Resolves filesystem identities once per configuration, then uses lexical
/// comparisons even for deleted paths. No realpath calls in the entry loop.
nonisolated struct FileIndexPathPolicy: Sendable {
    private let roots: [URL]
    /// `roots`' paths, precomposed. `URL.path` can hand back decomposed text,
    /// and ownership compares bytes, so every stored path is normalized once.
    let rootPaths: [String]
    let home: String
    let excludedPaths: [String]
    private let excludedNames: Set<String>

    init(roots: [URL], exclusions: [String]) {
        self.roots = roots.sorted { $0.path.count > $1.path.count }
        self.rootPaths = self.roots.map(\.path.precomposedStringWithCanonicalMapping)
        self.home = FileMetadataScanner.canonicalURL(FileManager.default.homeDirectoryForCurrentUser).path
            .precomposedStringWithCanonicalMapping
        var paths: [String] = []
        var names = Set<String>()
        for exclusion in exclusions {
            let expanded = (exclusion.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            guard !expanded.isEmpty else { continue }
            if expanded.hasPrefix("/") {
                paths.append(FileMetadataScanner.canonicalURL(URL(fileURLWithPath: expanded)).path
                    .precomposedStringWithCanonicalMapping)
            } else {
                names.insert(expanded)
            }
        }
        self.excludedPaths = paths
        self.excludedNames = names
    }

    func owner(of url: URL) -> URL? {
        self.owner(ofPath: url.standardized.path.precomposedStringWithCanonicalMapping)
    }

    /// The single implementation of ownership, over an already standardized,
    /// precomposed path. The URL overload delegates here so the off-main FSEvents
    /// prefilter and the main-actor queue can never disagree. It works on UTF-8
    /// bytes: it runs once per filesystem event, and most events are noise.
    func owner(ofPath path: String) -> URL? {
        let bytes = path.utf8
        guard let match = self.rootPaths.firstIndex(where: { Self.isWithin(bytes, directory: $0) })
        else { return nil }
        let (root, rootPath) = (self.roots[match], self.rootPaths[match])
        var rest = bytes.dropFirst(rootPath.utf8.count)
        var isFirst = true
        while !rest.isEmpty {
            let component = rest.prefix { $0 != Self.slash }
            rest = rest.dropFirst(component.count + 1)
            guard !component.isEmpty else { continue }
            if isFirst, rootPath == self.home, component.elementsEqual("Library".utf8) {
                return nil
            }
            isFirst = false
            if component.first == Self.dot {
                return nil
            }
            if !self.excludedNames.isEmpty,
               self.excludedNames.contains(String(Substring(component)))
            {
                return nil
            }
        }
        if self.excludedPaths.contains(where: { Self.isWithin(bytes, directory: $0) }) {
            return nil
        }
        return root
    }

    private static let slash = UInt8(ascii: "/")
    private static let dot = UInt8(ascii: ".")

    /// `path == directory || path.hasPrefix(directory + "/")`, byte-wise.
    private static func isWithin(_ path: String.UTF8View, directory: String) -> Bool {
        let prefix = directory.utf8
        guard path.starts(with: prefix) else { return false }
        return path.count == prefix.count || path[path.index(path.startIndex, offsetBy: prefix.count)] == self.slash
    }
}
