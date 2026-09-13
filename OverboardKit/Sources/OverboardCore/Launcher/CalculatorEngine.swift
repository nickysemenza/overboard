import Foundation
#if DEBUG
    import Playgrounds
#endif

/// Inline calculator for the launcher. Wraps `ArithmeticParser`: gates
/// "does this look like math" before evaluating, adds the `X% of Y` sugar,
/// and formats results deterministically.
public enum CalculatorEngine {
    public struct Evaluation: Sendable, Equatable {
        public let value: Double
        public let display: String

        public init(value: Double, display: String) {
            self.value = value
            self.display = display
        }
    }

    /// Returns nil when the input isn't math (the launcher shows no
    /// calculator row), including bare numbers, parse errors, and
    /// non-finite results like division by zero.
    public static func evaluate(_ input: String) -> Evaluation? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.looksLikeMath(trimmed) else { return nil }
        let normalized = self.preprocess(self.normalizeSeparators(trimmed))
        guard let value = ArithmeticParser.evaluate(normalized), value.isFinite else { return nil }
        return Evaluation(value: value, display: self.format(value))
    }

    // MARK: - Gating

    /// Words that may appear in an expression; any other letter-run means
    /// "this is prose, not math" — cheap insurance against evaluating
    /// arbitrary search queries.
    private static let functionWords: Set<String> = [
        "sqrt", "pow", "abs", "min", "max",
        "floor", "ceil", "round", "log",
    ]
    private static let allowedWords: Set<String> = functionWords.union(["of", "pi", "e"])

    private static let operatorCharacters = CharacterSet(charactersIn: "+-*/^%")
    private static let allowedPunctuation = CharacterSet(charactersIn: "+-*/^%().,")

    private static func looksLikeMath(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 256 else { return false }
        guard s.rangeOfCharacter(from: .decimalDigits) != nil else { return false }

        for scalar in s.unicodeScalars {
            let isLetter = CharacterSet.lowercaseLetters.contains(scalar)
                || CharacterSet.uppercaseLetters.contains(scalar)
            let ok = isLetter
                || CharacterSet.decimalDigits.contains(scalar)
                || CharacterSet.whitespaces.contains(scalar)
                || self.allowedPunctuation.contains(scalar)
            if !ok { return false }
        }

        let words = s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard words.allSatisfy({ self.allowedWords.contains($0) }) else { return false }

        // Something must actually compute: an operator, "of", or a function.
        let hasOperator = s.rangeOfCharacter(from: self.operatorCharacters) != nil
        let hasFunction = words.contains { self.functionWords.contains($0) || $0 == "of" }
        guard hasOperator || hasFunction else { return false }

        // A bare (possibly negative) number isn't worth a calculator row.
        return !self.trimmedOfBareNumberCharacters(s).isEmpty
    }

    /// Empty result means the string is just a number like "42", "-3.14",
    /// or "1,000" — digits, separators, and at most a leading minus.
    private static func trimmedOfBareNumberCharacters(_ s: String) -> String {
        var rest = Substring(s)
        if rest.first == "-" { rest = rest.dropFirst() }
        return rest.filter { !($0.isNumber || $0 == "." || $0 == "," || $0.isWhitespace) }
    }

    // MARK: - Locale separators

    /// In a comma-decimal locale, folds separators to the ASCII `.` decimal the
    /// parser wants, so `2,5+1` computes instead of silently failing. Only a `.`
    /// in true grouping position — immediately before exactly three digits that
    /// aren't themselves followed by a digit (`1.000`, `1.234.567`) — is dropped;
    /// any other `.` is treated as a cross-locale decimal point and kept, so a
    /// user who types `2.5+1` out of habit still gets `2.5+1`, not `25+1`. The
    /// decimal `,` then becomes `.`. In a period-decimal locale, commas are left
    /// untouched — there they're the parser's argument separator (`max(3, 7)`).
    ///
    /// Tradeoff: multi-argument functions written with comma separators don't
    /// work in comma-decimal locales, where the decimal use of `,` wins — but a
    /// bare decimal is by far the common launcher input.
    static func normalizeSeparators(
        _ s: String,
        decimalSeparator: String? = Locale.current.decimalSeparator
    ) -> String {
        guard decimalSeparator == "," else { return s }
        let degrouped = s.replacingOccurrences(
            of: #"\.(?=\d{3}(\D|$))"#, with: "", options: .regularExpression
        )
        return degrouped.replacingOccurrences(of: ",", with: ".")
    }

    // MARK: - Sugar

    /// "15% of 80" reads naturally; the parser just needs it spelled "*".
    private static func preprocess(_ s: String) -> String {
        s.replacingOccurrences(
            of: #"\bof\b"#,
            with: "*",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    // MARK: - Formatting

    /// Deterministic, locale-independent: integral values render without
    /// decimals, everything else with up to 10 significant digits.
    private static func format(_ value: Double) -> String {
        // Collapse negative zero (e.g. 0 * -5 == -0.0) so it never displays "-0".
        let value = value == 0 ? 0 : value
        if value == value.rounded(), abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.10g", value)
    }
}

#if DEBUG
    #Playground("Calculator expressions") {
        let inputs = [
            "12 + 30 * 2",
            "15% of 80",
            "2^10",
            "sqrt(144)",
            "42", // bare number — not worth a calculator row
        ]
        for input in inputs {
            print(input, "→", CalculatorEngine.evaluate(input) as Any)
        }
    }
#endif
