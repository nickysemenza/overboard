import Foundation

/// Deterministic markdown detection for the preview pane. Like SecretDetector,
/// intentionally conservative: a false positive renders prose through a
/// markdown engine (mildly wrong), but the preview's raw toggle is the escape
/// hatch either way.
public enum MarkdownDetector {
    private enum Marker: Hashable {
        case heading
        case bullet
        case orderedList
        case blockquote
        case fence
        case link
        case bold
        case tableRow
    }

    /// True when the text looks like authored markdown: at least two distinct
    /// marker kinds on multi-line input. Single-line input never qualifies —
    /// one stray `#` or `- ` is not a document.
    public static func looksLikeMarkdown(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count >= 2 else { return false }

        var markers: Set<Marker> = []
        for line in lines.prefix(200) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            if (1 ... 6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                markers.insert(.heading)
            }
            if let first = trimmed.first, "-*+".contains(first),
               trimmed.dropFirst().first == " ", trimmed.count >= 3
            {
                markers.insert(.bullet)
            }
            if let dot = trimmed.firstIndex(of: "."),
               !trimmed[..<dot].isEmpty, trimmed[..<dot].count <= 3,
               trimmed[..<dot].allSatisfy(\.isNumber),
               trimmed[trimmed.index(after: dot)...].first == " "
            {
                markers.insert(.orderedList)
            }
            if trimmed.first == ">", trimmed.dropFirst().first == " " {
                markers.insert(.blockquote)
            }
            if trimmed.hasPrefix("```") {
                markers.insert(.fence)
            }
            if trimmed.contains("["), trimmed.contains("](") {
                markers.insert(.link)
            }
            if trimmed.components(separatedBy: "**").count >= 3 {
                markers.insert(.bold)
            }
            if trimmed.first == "|", trimmed.dropFirst().contains("|") {
                markers.insert(.tableRow)
            }

            if markers.count >= 2 { return true }
        }
        return false
    }
}
