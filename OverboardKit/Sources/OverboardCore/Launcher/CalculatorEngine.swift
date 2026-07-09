import Expression
import Foundation

/// Inline calculator for the launcher. Thin wrapper around the Expression
/// package: gates "does this look like math" before evaluating, adds the
/// `^` / postfix-`%` / `X% of Y` sugar, and formats results deterministically.
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
        // Order matters: fold locale separators (removing any user commas) before
        // rewriting `^` to `pow(a, b)`, whose own commas are argument separators.
        let normalized = self.rewritePowers(self.normalizeSeparators(trimmed))
        let expression = Expression(
            preprocess(normalized),
            constants: ["pi": .pi, "e": M_E],
            symbols: [.postfix("%"): { $0[0] / 100 }]
        )
        guard let value = try? expression.evaluate(), value.isFinite else { return nil }
        return Evaluation(value: value, display: self.format(value))
    }

    // MARK: - Gating

    /// Words that may appear in an expression; any other letter-run means
    /// "this is prose, not math" — cheap insurance against evaluating
    /// arbitrary search queries.
    private static let functionWords: Set<String> = [
        "sqrt", "pow", "abs", "min", "max",
        "floor", "ceil", "round", "log", "exp",
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

    /// In a comma-decimal locale, folds the user's `,` decimal to the ASCII `.`
    /// the parser wants (and drops `.` grouping), so `2,5+1` computes instead of
    /// silently failing. In a period-decimal locale, commas are left untouched —
    /// there they're the parser's argument separator (`max(3, 7)`), and grouping
    /// like `1,000` is too ambiguous with that to strip safely.
    ///
    /// Tradeoff: multi-argument functions written with comma separators don't
    /// work in comma-decimal locales, where the decimal use of `,` wins — but a
    /// bare decimal is by far the common launcher input.
    static func normalizeSeparators(
        _ s: String,
        decimalSeparator: String? = Locale.current.decimalSeparator
    ) -> String {
        guard decimalSeparator == "," else { return s }
        return s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
    }

    // MARK: - Power operator

    /// Rewrites `a ^ b` into `pow(a, b)` so exponentiation gets standard math
    /// precedence and associativity from the parser. The Expression package binds
    /// unary minus tighter than a custom `^` (so `-2^2` wrongly gave `4`) and
    /// parses `^` left-associatively; `pow(...)` sidesteps both. Rewriting the
    /// right-most `^` first yields right associativity: `2^3^2` → `pow(2, pow(3, 2))`.
    /// A malformed `^` (no operand) is dropped so the parse fails cleanly (no row).
    private static func rewritePowers(_ input: String) -> String {
        var chars = Array(input)
        while let caret = chars.lastIndex(of: "^") {
            guard let left = self.leftOperand(chars, before: caret),
                  let right = self.rightOperand(chars, after: caret)
            else {
                // Malformed `^` (missing operand). Leave it in place: with no `^`
                // symbol registered, the parser rejects the whole input (no row),
                // rather than a silent drop that could evaluate a partial result.
                return String(chars)
            }
            let replacement = Array("pow(\(String(chars[left])),\(String(chars[right])))")
            chars.replaceSubrange(left.lowerBound ... right.upperBound, with: replacement)
        }
        return String(chars)
    }

    private static func isOperand(_ c: Character) -> Bool {
        c.isNumber || c == "." || c.isLetter || c == "_"
    }

    /// The primary immediately left of `caret`: a parenthesized group (with any
    /// leading function name) or a number/identifier run. Excludes a leading
    /// unary minus — that's the whole point of `-2^2` == `-(2^2)`.
    private static func leftOperand(_ s: [Character], before caret: Int) -> ClosedRange<Int>? {
        var i = caret - 1
        while i >= 0, s[i] == " " {
            i -= 1
        }
        guard i >= 0 else { return nil }
        let end = i
        if s[i] == ")" {
            var depth = 0
            while i >= 0 {
                if s[i] == ")" { depth += 1 } else if s[i] == "(" {
                    depth -= 1
                    if depth == 0 { break }
                }
                i -= 1
            }
            guard depth == 0, i >= 0 else { return nil }
            var j = i - 1 // absorb a preceding function name, e.g. sqrt(9)
            while j >= 0, self.isOperand(s[j]) {
                j -= 1
            }
            return (j + 1) ... end
        }
        guard self.isOperand(s[i]) else { return nil }
        while i >= 0, self.isOperand(s[i]) {
            i -= 1
        }
        return (i + 1) ... end
    }

    /// The primary immediately right of `caret`: an optional sign, then a
    /// parenthesized group, a function call, a number, or an identifier.
    private static func rightOperand(_ s: [Character], after caret: Int) -> ClosedRange<Int>? {
        var i = caret + 1
        while i < s.count, s[i] == " " {
            i += 1
        }
        let start = i
        while i < s.count, s[i] == "+" || s[i] == "-" {
            i += 1
        }
        while i < s.count, s[i] == " " {
            i += 1
        }
        guard i < s.count else { return nil }
        if s[i] == "(" {
            guard let close = self.matchParen(s, from: i) else { return nil }
            return start ... close
        }
        guard self.isOperand(s[i]) else { return nil }
        while i < s.count, self.isOperand(s[i]) {
            i += 1
        }
        if i < s.count, s[i] == "(", let close = self.matchParen(s, from: i) {
            return start ... close // function call
        }
        return start ... (i - 1)
    }

    /// Index of the `)` matching the `(` at `open`, or nil if unbalanced.
    private static func matchParen(_ s: [Character], from open: Int) -> Int? {
        var depth = 0
        var i = open
        while i < s.count {
            if s[i] == "(" { depth += 1 } else if s[i] == ")" {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    // MARK: - Sugar

    /// "15% of 80" reads naturally; Expression just needs it spelled "*".
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
