import Foundation

/// A "when copying from this app, clean the text this way" rule. Reuses the
/// same `ClipTransform` functions offered manually via "Paste Transformed", but
/// applies them automatically at capture time — e.g. strip tracking params from
/// every browser copy, trim every terminal copy.
public struct AutoTransformRule: Equatable, Sendable {
    public let bundleID: String
    public let transform: ClipTransform

    public init(bundleID: String, transform: ClipTransform) {
        self.bundleID = bundleID
        self.transform = transform
    }
}

public enum AutoTransform {
    /// Parses the settings text — one `bundleID = transform` per line, where
    /// `transform` is a `ClipTransform` raw value (e.g.
    /// `com.apple.Safari = stripTrackingParams`). Blank lines and lines whose
    /// transform is unrecognized are skipped. Order is preserved so multiple
    /// rules for one app apply in sequence.
    public static func parseRules(_ raw: String) -> [AutoTransformRule] {
        raw.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let bundleID = parts[0].trimmingCharacters(in: .whitespaces)
            let transformRaw = parts[1].trimmingCharacters(in: .whitespaces)
            guard !bundleID.isEmpty, let transform = ClipTransform(rawValue: transformRaw)
            else { return nil }
            return AutoTransformRule(bundleID: bundleID, transform: transform)
        }
    }

    /// Applies every rule matching `bundleID` to `text`, in order. Returns the
    /// transformed text only when it actually changed and at least one rule
    /// matched; nil otherwise (so callers can skip rewriting the snapshot).
    public static func apply(to text: String, bundleID: String?, rules: [AutoTransformRule]) -> String? {
        guard let bundleID else { return nil }
        let matching = rules.filter { $0.bundleID == bundleID }
        guard !matching.isEmpty else { return nil }
        let result = matching.reduce(text) { $1.transform.apply(to: $0) }
        return result == text ? nil : result
    }
}
