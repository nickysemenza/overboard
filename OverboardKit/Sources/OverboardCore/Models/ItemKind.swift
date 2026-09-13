import Foundation

public enum ItemKind: String, Codable, Sendable, CaseIterable {
    case text
    case link
    case image
    case file
    case color
}

/// A named entry in the "kind identity" ramp (DESIGN.md § Colors). Core names
/// the tint; `OverboardUI` is the single place that turns a name into a
/// `SwiftUI.Color`, so the data layer stays free of AppKit/SwiftUI.
public enum KindTint: String, Sendable, CaseIterable {
    case gray
    case blue
    case purple
    case teal
    case orange
}

// MARK: - Presentation

/// The one kind → symbol/label/tint map. Four copies of this switch used to
/// live in the launcher row, the drawer card, Settings, and the debug history
/// window, and they had already drifted (two different "text" symbols).
public extension ItemKind {
    /// SF Symbol standing in for this kind wherever no richer artwork (app
    /// icon, thumbnail, file icon) is available.
    var symbolName: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        case .color: "paintpalette"
        }
    }

    /// Capitalized, standalone name ("Text", "Link") for pickers, badges, and
    /// metadata rows.
    var displayName: String {
        switch self {
        case .text: String(localized: "Text")
        case .link: String(localized: "Link")
        case .image: String(localized: "Image")
        case .file: String(localized: "File")
        case .color: String(localized: "Color")
        }
    }

    /// This kind's place in the kind-identity ramp.
    var tintName: KindTint {
        switch self {
        case .text: .gray
        case .link: .blue
        case .image: .purple
        case .file: .teal
        case .color: .orange
        }
    }

    /// Counted, lowercase phrase for summaries ("1 link", "96 links").
    func countLabel(_ count: Int) -> String {
        switch self {
        // "text" is a mass noun in this summary — "812 texts" would read as
        // messages, not as text clips — so it never takes a plural.
        case .text: String(localized: "\(count.formatted()) text")
        case .link: CountPhrase.string(count, of: String(localized: "link"))
        case .image: CountPhrase.string(count, of: String(localized: "image"))
        case .file: CountPhrase.string(count, of: String(localized: "file"))
        case .color: CountPhrase.string(count, of: String(localized: "color"))
        }
    }
}
