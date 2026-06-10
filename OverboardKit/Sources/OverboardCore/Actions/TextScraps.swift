import Foundation

/// Pure text utilities backing clip actions.
public enum TextScraps {
    /// All http(s) links found by the system data detector.
    public static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range)
            .compactMap(\.url)
            .filter { $0.scheme == "http" || $0.scheme == "https" }
    }

    /// Numbers extracted from free text. Handles negatives, decimals, and
    /// thousands separators ("1,200.50"); ignores everything else.
    public static func numbers(in text: String) -> [Double] {
        let pattern = /-?\d[\d,]*(?:\.\d+)?/
        return text.matches(of: pattern).compactMap { match in
            Double(match.output.replacingOccurrences(of: ",", with: ""))
        }
    }

    /// Trims trailing ".0" for whole numbers, keeps decimals otherwise.
    public static func format(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(value)
    }

    /// Preview-text heuristic: JSON-shaped enough to offer pretty-printing.
    public static func looksLikeJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, let first = trimmed.first else { return false }
        return first == "{" || first == "["
    }

    /// Preview-text heuristic: plausibly Base64. Requires the alphabet, some
    /// length, and at least one non-lowercase character so ordinary words
    /// don't qualify. Tolerates length % 4 ≠ 0 only for truncated previews.
    public static func looksLikeBase64(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else { return false }
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        guard trimmed.allSatisfy({ alphabet.contains($0) }) else { return false }
        let hasBase64Flavor = trimmed.contains {
            $0.isUppercase || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "="
        }
        return hasBase64Flavor && (trimmed.count.isMultiple(of: 4) || trimmed.count >= 400)
    }

    public static func prettyPrintedJSON(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys]
              )
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }
}
