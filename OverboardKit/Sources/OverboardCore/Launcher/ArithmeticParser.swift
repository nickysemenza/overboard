import Foundation

/// A small recursive-descent evaluator for the launcher's calculator: the
/// arithmetic subset a user types into a search bar, and nothing else.
///
/// It replaces a general expression package, so the grammar is deliberately
/// fixed and documented here rather than assembled from a symbol table:
///
/// ```
/// expression  := term (('+' | '-') term)*
/// term        := unary (('*' | '/' | '%') unary)*      // infix '%' is fmod
/// unary       := ('+' | '-') unary | power
/// power       := postfix ('^' unary)?                  // right-associative
/// postfix     := primary '%'*                          // percent-of-one-hundred
/// primary     := number | constant | call | '(' expression ')'
/// call        := identifier '(' expression (',' expression)* ')'
/// ```
///
/// Two precedence choices are load-bearing and pinned by tests:
/// `^` binds tighter than unary minus (`-2^2 == -4`) and is right-associative
/// (`2^3^2 == 512`). Both fall out of `unary` sitting above `power` while
/// `power`'s right-hand side recurses back into `unary`.
///
/// `%` is percent (divide by one hundred) in postfix position and modulo when
/// an operand follows it, matching what the launcher's inputs have always
/// meant: `100 + 10%` is 100.1, `10 % 3` is 1.
public enum ArithmeticParser {
    /// Evaluates a fully normalized expression, or returns nil when the input
    /// isn't a well-formed one (unbalanced parens, a trailing operator, an
    /// unknown name, leftover tokens, or an empty string). Callers decide what
    /// to do with non-finite results like `1/0`; this returns them as-is.
    public static func evaluate(_ input: String) -> Double? {
        guard let tokens = Lexer.tokenize(input) else { return nil }
        var parser = Parser(tokens: tokens)
        guard let value = parser.parseExpression(depth: 0), parser.isAtEnd else { return nil }
        return value
    }

    // MARK: - Symbols

    struct Function {
        let arity: ClosedRange<Int>
        let apply: @Sendable ([Double]) -> Double
    }

    /// The functions the calculator exposes. Kept to the set the launcher has
    /// always been able to reach: the gate in `CalculatorEngine` rejects any
    /// other word before evaluation is ever attempted.
    static let functions: [String: Function] = [
        "sqrt": Function(arity: 1 ... 1) { sqrt($0[0]) },
        "floor": Function(arity: 1 ... 1) { floor($0[0]) },
        "ceil": Function(arity: 1 ... 1) { ceil($0[0]) },
        "round": Function(arity: 1 ... 1) { $0[0].rounded() },
        "abs": Function(arity: 1 ... 1) { abs($0[0]) },
        // Natural logarithm, as the previous expression package defined it.
        "log": Function(arity: 1 ... 1) { log($0[0]) },
        "pow": Function(arity: 2 ... 2) { pow($0[0], $0[1]) },
        "max": Function(arity: 2 ... Int.max) { $0.dropFirst().reduce($0[0], Swift.max) },
        "min": Function(arity: 2 ... Int.max) { $0.dropFirst().reduce($0[0], Swift.min) },
    ]

    static let constants: [String: Double] = ["pi": .pi, "e": M_E]

    /// Guards against a stack overflow from pathological nesting. The launcher
    /// caps input at 256 characters, so no real expression comes close.
    static let maximumDepth = 64

    // MARK: - Tokens

    enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case symbol(Character)

        /// True for the tokens that can begin an operand, which is how a
        /// postfix `%` is told apart from an infix one.
        var startsOperand: Bool {
            switch self {
            case .number, .identifier: true
            case let .symbol(character): character == "("
            }
        }
    }

    enum Lexer {
        static let symbols: Set<Character> = ["+", "-", "*", "/", "^", "%", "(", ")", ","]

        /// Returns nil on any character the grammar has no token for, or on a
        /// malformed number such as `1..2`.
        static func tokenize(_ input: String) -> [Token]? {
            var tokens: [Token] = []
            let characters = Array(input)
            var index = 0
            while index < characters.count {
                let character = characters[index]
                if character.isWhitespace {
                    index += 1
                } else if character.isNumber || character == "." {
                    guard let token = self.scanNumber(characters, from: &index) else { return nil }
                    tokens.append(token)
                } else if character.isLetter || character == "_" {
                    var end = index
                    while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" {
                        end += 1
                    }
                    tokens.append(.identifier(String(characters[index ..< end])))
                    index = end
                } else if self.symbols.contains(character) {
                    tokens.append(.symbol(character))
                    index += 1
                } else {
                    return nil
                }
            }
            return tokens
        }

        /// Digits and decimal points, then an optional `e`/`E` exponent — but
        /// only when a signed integer actually follows, so `2*e` still reads
        /// the constant `e` rather than swallowing it into the number.
        private static func scanNumber(_ characters: [Character], from index: inout Int) -> Token? {
            var end = index
            while end < characters.count, characters[end].isNumber || characters[end] == "." {
                end += 1
            }
            var text = String(characters[index ..< end])
            if end < characters.count, characters[end] == "e" || characters[end] == "E" {
                var exponentEnd = end + 1
                if exponentEnd < characters.count, characters[exponentEnd] == "+" || characters[exponentEnd] == "-" {
                    exponentEnd += 1
                }
                if exponentEnd < characters.count, characters[exponentEnd].isNumber {
                    while exponentEnd < characters.count, characters[exponentEnd].isNumber {
                        exponentEnd += 1
                    }
                    text += String(characters[end ..< exponentEnd])
                    end = exponentEnd
                }
            }
            // `Double.init` is the arbiter: it rejects "1..2" and a bare ".".
            guard let value = Double(text) else { return nil }
            index = end
            return .number(value)
        }
    }

    // MARK: - Parser

    struct Parser {
        let tokens: [Token]
        var index = 0

        var isAtEnd: Bool {
            self.index >= self.tokens.count
        }

        func peek(_ offset: Int = 0) -> Token? {
            let target = self.index + offset
            return target < self.tokens.count ? self.tokens[target] : nil
        }

        mutating func match(_ character: Character) -> Bool {
            guard self.peek() == .symbol(character) else { return false }
            self.index += 1
            return true
        }

        mutating func parseExpression(depth: Int) -> Double? {
            guard depth <= ArithmeticParser.maximumDepth else { return nil }
            guard var value = self.parseTerm(depth: depth) else { return nil }
            while case let .symbol(character)? = self.peek(), character == "+" || character == "-" {
                self.index += 1
                guard let rhs = self.parseTerm(depth: depth) else { return nil }
                value = character == "+" ? value + rhs : value - rhs
            }
            return value
        }

        private mutating func parseTerm(depth: Int) -> Double? {
            guard var value = self.parseUnary(depth: depth) else { return nil }
            while case let .symbol(character)? = self.peek(), character == "*" || character == "/" || character == "%" {
                self.index += 1
                guard let rhs = self.parseUnary(depth: depth) else { return nil }
                switch character {
                case "*": value *= rhs
                case "/": value /= rhs
                default: value = fmod(value, rhs)
                }
            }
            return value
        }

        private mutating func parseUnary(depth: Int) -> Double? {
            if case let .symbol(character)? = self.peek(), character == "-" || character == "+" {
                self.index += 1
                guard let value = self.parseUnary(depth: depth + 1) else { return nil }
                return character == "-" ? -value : value
            }
            return self.parsePower(depth: depth)
        }

        private mutating func parsePower(depth: Int) -> Double? {
            guard let base = self.parsePostfix(depth: depth) else { return nil }
            guard self.match("^") else { return base }
            // Recursing into `unary` gives right associativity and lets the
            // exponent carry its own sign (`2^-2`).
            guard let exponent = self.parseUnary(depth: depth + 1) else { return nil }
            return pow(base, exponent)
        }

        private mutating func parsePostfix(depth: Int) -> Double? {
            guard var value = self.parsePrimary(depth: depth) else { return nil }
            // A `%` with an operand after it is the infix modulo `parseTerm`
            // handles; anything else makes it the percent suffix.
            while self.peek() == .symbol("%"), self.peek(1)?.startsOperand != true {
                self.index += 1
                value /= 100
            }
            return value
        }

        private mutating func parsePrimary(depth: Int) -> Double? {
            guard depth <= ArithmeticParser.maximumDepth, let token = self.peek() else { return nil }
            switch token {
            case let .number(value):
                self.index += 1
                return value
            case let .identifier(name):
                self.index += 1
                if self.match("(") { return self.finishCall(name: name, depth: depth) }
                return ArithmeticParser.constants[name]
            case .symbol("("):
                self.index += 1
                guard let value = self.parseExpression(depth: depth + 1), self.match(")") else { return nil }
                return value
            case .symbol:
                return nil
            }
        }

        /// Parses the argument list of `name(` and applies the function.
        private mutating func finishCall(name: String, depth: Int) -> Double? {
            guard let function = ArithmeticParser.functions[name] else { return nil }
            var arguments: [Double] = []
            repeat {
                guard let argument = self.parseExpression(depth: depth + 1) else { return nil }
                arguments.append(argument)
            } while self.match(",")
            guard self.match(")"), function.arity.contains(arguments.count) else {
                return nil
            }
            return function.apply(arguments)
        }
    }
}
