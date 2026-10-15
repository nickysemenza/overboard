import Darwin
import Foundation

/// Noise location (GLOSSARY.md) detection. Nothing here names a folder:
/// detection comes from traits the paths already carry, and the only lists
/// are the user's own.
public enum NoiseClassifier {
    /// Package managers stamp versions into folder names (`parser@v1.2.3`,
    /// `lodash-4.17.21`); people rarely do. Callers apply this to folder
    /// names only — a downloaded `app-1.2.3.dmg` is still the user's own file.
    public static func isVersionStamped(folderName: String) -> Bool {
        folderName.contains(/[@-]v?\d+(\.\d+)+/)
    }
}

/// The user's Settings lists: folders marked as noise, and folders marked as
/// not noise to correct a wrong detection. Applied when ranking rather than
/// indexing, so an edit takes effect on the next keystroke without a rescan.
public struct NoiseRules: Sendable, Equatable {
    private let noise: [Entry]
    private let notNoise: [Entry]

    public init(noise: String = "", notNoise: String = "") {
        self.noise = Self.entries(noise)
        self.notNoise = Self.entries(notNoise)
    }

    /// Not-noise wins over both detection and the noise list.
    public func isNoise(path: String, detected: Bool) -> Bool {
        if self.notNoise.contains(where: { $0.covers(path) }) {
            return false
        }
        return detected || self.noise.contains { $0.covers(path) }
    }

    /// Same line format as Excluded folders: an absolute (or `~`) path covers
    /// that folder, a bare name covers any folder with that name.
    private enum Entry: Sendable, Equatable {
        case path(String), name(String)

        func covers(_ path: String) -> Bool {
            switch self {
            case let .path(folder): path.hasPrefix(folder + "/")
            case let .name(name): path.contains("/" + name + "/")
            }
        }
    }

    private static func entries(_ text: String) -> [Entry] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let expanded = (trimmed as NSString).expandingTildeInPath.precomposedStringWithCanonicalMapping
            if expanded.hasPrefix("/") {
                return .path(expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded)
            }
            return .name(expanded)
        }
    }
}

/// The subset of `.gitignore` needed to recognise generated folders: plain
/// and glob patterns, anchored or not, directory-only or not. Negations are
/// skipped — the cost of missing one is a demoted file, not a hidden one.
public struct GitIgnoreRules: Sendable {
    private struct Pattern: Sendable {
        let glob: String
        let anchored: Bool
        let directoryOnly: Bool
    }

    private let patterns: [Pattern]

    public var isEmpty: Bool {
        self.patterns.isEmpty
    }

    public init(_ contents: String) {
        self.patterns = contents.split(whereSeparator: \.isNewline).compactMap { line in
            var text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("#"), !text.hasPrefix("!") else { return nil }
            let directoryOnly = text.hasSuffix("/")
            if directoryOnly {
                text.removeLast()
            }
            if text.hasPrefix("**/") {
                text.removeFirst(3)
            }
            let anchored = text.contains("/")
            if text.hasPrefix("/") {
                text.removeFirst()
            }
            guard !text.isEmpty, text != "*" else { return nil }
            return Pattern(glob: text, anchored: anchored, directoryOnly: directoryOnly)
        }
    }

    /// `relativePath` is from the folder holding the `.gitignore`.
    public func ignores(relativePath: String, isDirectory: Bool) -> Bool {
        let name = (relativePath as NSString).lastPathComponent
        return self.patterns.contains { pattern in
            guard !pattern.directoryOnly || isDirectory else { return false }
            return fnmatch(pattern.glob, pattern.anchored ? relativePath : name, FNM_PATHNAME) == 0
        }
    }
}
