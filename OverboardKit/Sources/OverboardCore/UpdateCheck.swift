import Foundation

/// A dotted release version parsed from a git tag like `v0.2.0` or `0.2.0`.
/// Comparison is numeric per-component, so `0.10.0` > `0.9.0`. A `-suffix`
/// (pre-release / `git describe` drift like `v0.1.0-3-gabc`) is ignored for
/// ordering — we only compare the release numbers.
public struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let components: [Int]

    /// Parses `v1.2.3`, `1.2`, `release-2.0.0`, etc. Returns nil when no
    /// dotted numeric core can be found.
    public init?(_ raw: String) {
        // Drop everything up to the first digit (strips a leading "v" or name),
        // then keep the leading numeric-dotted run (drops a "-3-gabc" suffix).
        guard let firstDigit = raw.firstIndex(where: \.isNumber) else { return nil }
        var core = ""
        for char in raw[firstDigit...] {
            if char.isNumber || char == "." { core.append(char) } else { break }
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: true).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.components = parts.compactMap(\.self)
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0 ..< count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    /// Trailing zeros don't matter: `1.2` equals `1.2.0`. Kept consistent with
    /// `<` so `Comparable`'s derived operators behave.
    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public var description: String {
        self.components.map(String.init).joined(separator: ".")
    }
}

/// Pure decision logic for "is there a newer release than what's running?".
/// The networking that fetches `latestTag` lives in the platform layer; this
/// stays testable and dependency-free.
public enum UpdateCheck {
    /// Returns the latest tag when it parses to a strictly greater version than
    /// `current`, else nil. Unparseable inputs yield nil (never a false alarm).
    public static func newerRelease(current: String, latestTag: String) -> String? {
        guard let currentVersion = SemanticVersion(current),
              let latestVersion = SemanticVersion(latestTag)
        else { return nil }
        return latestVersion > currentVersion ? latestTag : nil
    }
}
