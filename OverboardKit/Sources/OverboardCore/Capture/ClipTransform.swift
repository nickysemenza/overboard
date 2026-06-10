import Foundation

/// Text transforms applicable at paste time ("Paste Transformed" in the
/// card context menu). Pure functions.
public enum ClipTransform: String, Sendable, CaseIterable, Identifiable {
    case stripTrackingParams
    case trimWhitespace
    case lowercase
    case uppercase

    public var id: String {
        self.rawValue
    }

    public var label: String {
        switch self {
        case .stripTrackingParams: "Strip Tracking Params"
        case .trimWhitespace: "Trim Whitespace"
        case .lowercase: "lowercase"
        case .uppercase: "UPPERCASE"
        }
    }

    /// Whether this transform makes sense for the given kind of clip.
    public func applies(to kind: ItemKind) -> Bool {
        switch self {
        case .stripTrackingParams: kind == .link
        case .trimWhitespace, .lowercase, .uppercase: kind == .text
        }
    }

    public func apply(to text: String) -> String {
        switch self {
        case .trimWhitespace:
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .lowercase:
            text.lowercased()
        case .uppercase:
            text.uppercased()
        case .stripTrackingParams:
            Self.stripTracking(from: text)
        }
    }

    /// Query parameters that exist purely to track the click.
    private static let trackingParams: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "msclkid", "twclid",
        "mc_cid", "mc_eid", "igshid", "igsh", "si", "ref_src", "ref_url",
        "vero_id", "wickedid", "yclid", "_hsenc", "_hsmi", "s_cid", "mkt_tok",
    ]

    private static func stripTracking(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return text }
        guard let items = components.queryItems, !items.isEmpty else { return text }

        let kept = items.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !self.trackingParams.contains(name)
        }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.string ?? text
    }
}
