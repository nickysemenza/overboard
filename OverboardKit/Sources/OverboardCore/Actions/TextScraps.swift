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
