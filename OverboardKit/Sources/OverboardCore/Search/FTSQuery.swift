import Foundation

/// Builds an FTS5 MATCH expression from raw user input.
/// Every token is quoted (so user input can't inject FTS syntax) and the last
/// token gets a trailing `*`, which makes type-ahead feel fuzzy.
public enum FTSQuery {
    public static func match(for input: String) -> String? {
        let tokens = input
            .split(whereSeparator: \.isWhitespace)
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        var quoted = tokens.map { "\"\($0)\"" }
        quoted[quoted.count - 1] += "*"
        return quoted.joined(separator: " ")
    }
}
