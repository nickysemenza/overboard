import Foundation

public enum TemplateEngine {
    public struct Context: Sendable {
        public let now: Date
        public let clipboard: String?
        public let uuid: @Sendable () -> String
        private var capturedBody: String?
        private var capturedUUIDs: [String]?

        public init(
            now: Date = Date(), clipboard: String? = nil,
            uuid: @escaping @Sendable () -> String = { UUID().uuidString }
        ) {
            self.now = now
            self.clipboard = clipboard
            self.uuid = uuid
        }

        public static func capture(
            for body: String, clipboard: String? = nil, now: Date = Date(),
            uuidFactory: @escaping @Sendable () -> String = { UUID().uuidString }
        ) -> Context {
            Context(now: now, clipboard: clipboard, uuid: uuidFactory).captured(for: body)
        }

        public func captured(for body: String) -> Context {
            guard self.capturedBody != body else { return self }
            var captured = self
            captured.capturedBody = body
            captured.capturedUUIDs = TemplateEngine.tokens(in: body).compactMap { token in
                guard token.kind == .legacy("uuid") else { return nil }
                return self.uuid()
            }
            return captured
        }

        fileprivate func uuidValues(for body: String) -> [String]? {
            self.capturedBody == body ? self.capturedUUIDs : nil
        }
    }

    public struct Invocation: Sendable {
        private let body: String
        private let context: Context
        public init(_ body: String, context: Context = Context()) {
            self.body = body
            self.context = context.captured(for: body)
        }

        public func preview(arguments: [String: String] = [:]) -> String {
            TemplateEngine.preview(self.body, arguments: arguments, context: self.context)
        }

        public func expand(arguments: [String: String] = [:]) throws -> String {
            try TemplateEngine.expand(self.body, arguments: arguments, context: self.context)
        }
    }

    public struct Argument: Sendable, Equatable, Identifiable {
        public let name: String
        public let defaultValue: String?
        public var id: String {
            self.name
        }
    }

    public enum TokenKind: Sendable, Equatable {
        case legacy(String)
        case argument(Argument)
        case formattedDate(String)
        case unknown
    }

    public struct Token: Sendable, Equatable {
        public let rawValue: String
        public let kind: TokenKind
    }

    public typealias Error = FormatError

    public enum FormatError: Swift.Error, Sendable, Equatable, LocalizedError {
        case missingArguments([String])

        public var errorDescription: String? {
            switch self {
            case let .missingArguments(names): "Values required for: \(names.joined(separator: ", "))."
            }
        }
    }

    public static func tokens(in body: String) -> [Token] {
        self.matches(in: body).map { self.token(String(body[$0])) }
    }

    public static func arguments(in body: String) -> [Argument] {
        var arguments: [Argument] = []
        for token in self.tokens(in: body) {
            guard case let .argument(argument) = token.kind else { continue }
            if let index = arguments.firstIndex(where: { $0.name == argument.name }) {
                if arguments[index].defaultValue == nil, argument.defaultValue != nil {
                    arguments[index] = argument
                }
            } else {
                arguments.append(argument)
            }
        }
        return arguments
    }

    public static func expand(
        _ body: String, arguments: [String: String] = [:], context: Context = Context()
    ) throws -> String {
        try self.requireArguments(in: body, arguments: arguments)
        let uuidValues = context.uuidValues(for: body)
        if !body.contains("{{"), uuidValues == nil {
            return SnippetTemplate.expand(body, now: context.now, clipboard: context.clipboard, uuid: context.uuid)
        }
        return self.render(body, arguments: arguments, context: context, preview: false, uuidValues: uuidValues)
    }

    public static func preview(
        _ body: String, arguments: [String: String] = [:], context: Context = Context()
    ) -> String {
        self.render(
            body,
            arguments: arguments,
            context: context,
            preview: true,
            uuidValues: context.uuidValues(for: body)
        )
    }

    private static func render(
        _ body: String, arguments: [String: String], context: Context, preview: Bool, uuidValues: [String]? = nil
    ) -> String {
        let defaults = Dictionary(uniqueKeysWithValues: self.arguments(in: body).compactMap { argument in
            argument.defaultValue.map { (argument.name, $0) }
        })
        var result = ""
        var position = body.startIndex
        var uuidIndex = 0
        for range in self.matches(in: body) {
            result += body[position ..< range.lowerBound]
            let token = self.token(String(body[range]))
            switch token.kind {
            case let .argument(argument):
                result += arguments[argument.name] ?? defaults[argument.name] ?? token.rawValue
            case let .formattedDate(format):
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = format
                result += formatter.string(from: context.now)
            case let .legacy(name):
                if name == "uuid", let uuidValues {
                    result += uuidValues[uuidIndex]
                    uuidIndex += 1
                } else if preview, name == "uuid" || (name == "clipboard" && context.clipboard == nil) {
                    result += token.rawValue
                } else {
                    result += SnippetTemplate.expand(
                        token.rawValue, now: context.now, clipboard: context.clipboard, uuid: context.uuid
                    )
                }
            case .unknown:
                result += token.rawValue
            }
            position = range.upperBound
        }
        result += body[position...]
        return result
    }

    private static func requireArguments(in body: String, arguments: [String: String]) throws {
        let missing = self.arguments(in: body).filter {
            arguments[$0.name] == nil && $0.defaultValue == nil
        }.map(\.name)
        guard missing.isEmpty else { throw Error.missingArguments(missing) }
    }

    private static func matches(in body: String) -> [Range<String.Index>] {
        guard let expression = try? NSRegularExpression(pattern: #"\{\{[^{}]*\}\}|\{[^{}]*\}"#)
        else { return [] }
        return expression.matches(in: body, range: NSRange(body.startIndex..., in: body))
            .compactMap { Range($0.range, in: body) }
    }

    private static func token(_ raw: String) -> Token {
        guard raw.hasPrefix("{{") else {
            let name = String(raw.dropFirst().dropLast())
            return Token(rawValue: raw, kind: ["date", "time", "datetime", "uuid", "clipboard"].contains(name)
                ? .legacy(name) : .unknown)
        }
        let content = String(raw.dropFirst(2).dropLast(2))
        for name in ["date", "time", "datetime"] where content.hasPrefix("\(name):") {
            let format = String(content.dropFirst(name.count + 1))
            return Token(rawValue: raw, kind: format.isEmpty ? .unknown : .formattedDate(format))
        }
        let parts = content.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard let namePart = parts.first else { return Token(rawValue: raw, kind: .unknown) }
        let name = String(namePart)
        guard let first = name.first, first.isLetter || first == "_",
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
        else { return Token(rawValue: raw, kind: .unknown) }
        return Token(rawValue: raw, kind: .argument(Argument(
            name: name, defaultValue: parts.count == 2 ? String(parts[1]) : nil
        )))
    }
}
