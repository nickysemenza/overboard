import Foundation
#if DEBUG
    import Playgrounds
#endif

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
            markers.formUnion(self.markers(in: trimmed))
            if markers.count >= 2 {
                return true
            }
        }
        return false
    }

    /// Every marker kind a single (already-trimmed) line matches.
    private static func markers(in trimmed: String) -> Set<Marker> {
        var markers: Set<Marker> = []
        if self.isHeading(trimmed) {
            markers.insert(.heading)
        }
        if self.isBullet(trimmed) {
            markers.insert(.bullet)
        }
        if self.isOrderedListItem(trimmed) {
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
        return markers
    }

    private static func isHeading(_ trimmed: String) -> Bool {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        return (1 ... 6).contains(hashes) && trimmed.dropFirst(hashes).first == " "
    }

    private static func isBullet(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, "-*+".contains(first) else { return false }
        return trimmed.dropFirst().first == " " && trimmed.count >= 3
    }

    private static func isOrderedListItem(_ trimmed: String) -> Bool {
        guard let dot = trimmed.firstIndex(of: ".") else { return false }
        let digits = trimmed[..<dot]
        return !digits.isEmpty
            && digits.count <= 3
            && digits.allSatisfy(\.isNumber)
            && trimmed[trimmed.index(after: dot)...].first == " "
    }
}

#if DEBUG
    #Playground("Markdown detection") {
        let samples = [
            "# Title\n- bullet item", // heading + bullet: two marker kinds → true
            "- one\n- two\n- three", // bullet only: one marker kind → false
            "```swift\nlet x = 1\n```", // fence only: one marker kind → false
            "Just an ordinary\ntwo-line paragraph.", // prose: no markers → false
            "https://example.com", // single line never qualifies → false
        ]
        for sample in samples {
            print(sample, "→", MarkdownDetector.looksLikeMarkdown(sample))
        }
    }
#endif
