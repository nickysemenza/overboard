import Foundation

/// Presentation helpers for pinned drawer searches. The saved value is just the
/// raw query string (so it runs through the exact same search path as typing
/// it); this turns one into a friendly chip label by reading its operators.
public enum SavedSearch {
    /// A short human label for a saved query, e.g. `kind:image app:slack` →
    /// "Images in Slack", `todo kind:text` → "Text “todo”". Falls back to the
    /// raw query when it carries no recognized operators.
    public static func label(for query: String) -> String {
        let parsed = ParsedQuery.parse(query)
        // A plain text query reads best as-is — only dress it up once operators
        // are involved, where the raw string ("kind:image app:slack") is cryptic.
        guard parsed.hasFilters else {
            return query.trimmingCharacters(in: .whitespaces)
        }
        var parts: [String] = []
        if let kind = parsed.kind { parts.append(self.pluralKind(kind)) }
        if let category = parsed.category { parts.append(category.capitalized) }
        if !parsed.text.isEmpty { parts.append("“\(parsed.text)”") }
        if let app = parsed.app { parts.append("in \(app.capitalized)") }
        let label = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? query : label
    }

    private static func pluralKind(_ kind: ItemKind) -> String {
        switch kind {
        case .text: "Text"
        case .link: "Links"
        case .image: "Images"
        case .file: "Files"
        case .color: "Colors"
        }
    }
}
