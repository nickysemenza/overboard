import Foundation

public enum LauncherScope: String, CaseIterable, Sendable, Identifiable {
    case all = "All", files = "Files", clipboard = "Clipboard", apps = "Apps"

    public var id: String {
        self.rawValue
    }

    public func includes(_ result: LauncherResult) -> Bool {
        switch (self, result) {
        case (.all, _), (.files, .file), (.clipboard, .clip), (.apps, .app): true
        default: false
        }
    }
}

/// Comparable across providers. Learning is applied only within a tier.
public struct SearchMatch: Sendable, Equatable {
    public enum Tier: Int, Comparable, Sendable {
        case exact, prefix, words, substring, fuzzy, related

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let tier: Tier
    public let highlights: [NSRange]

    public init(tier: Tier, highlights: [NSRange] = []) {
        self.tier = tier
        self.highlights = highlights
    }
}

/// Shared, deterministic matching for filenames, paths, apps and launcher rows.
public enum SearchMatcher {
    public static func tokens(_ text: String) -> [String] {
        AppMatcher.fold(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// FTS tokenizers discard punctuation. Preserve programming-language
    /// queries such as c++ and c# instead of treating them as the prefix c.
    public static func literalTerm(_ query: String) -> String? {
        let term = AppMatcher.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return !term.contains(where: \.isWhitespace) && (term.contains("+") || term.contains("#")) ? term : nil
    }

    public struct PreparedQuery: Sendable {
        let needle: String
        let tokens: [String]
        let literal: String?

        public init(_ query: String) {
            self.needle = AppMatcher.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
            self.tokens = SearchMatcher.tokens(self.needle)
            self.literal = SearchMatcher.literalTerm(self.needle)
        }

        /// File indexes already persist folded fields. Avoid repeated locale
        /// folding and query tokenization for every retrieved candidate.
        public func tier(foldedTitle name: String, foldedContext context: String) -> SearchMatch.Tier? {
            guard !self.needle.isEmpty else { return .related }
            if name == self.needle || (name as NSString).deletingPathExtension == self.needle {
                return .exact
            }
            if name.hasPrefix(self.needle) {
                return .prefix
            }
            if let literal {
                return (name + " " + context).contains(literal) ? .substring : nil
            }
            guard !self.tokens.isEmpty else { return name.contains(self.needle) ? .substring : nil }
            let words = (name + " " + context).split { !$0.isLetter && !$0.isNumber }.map(String.init)
            var tier = SearchMatch.Tier.words
            for token in self.tokens {
                if words.contains(where: { $0.hasPrefix(token) }) {
                    continue
                }
                if token.count >= 3, words.contains(where: { $0.contains(token) }) {
                    tier = max(tier, .substring)
                    continue
                }
                if token.count >= 4, words.contains(where: { SearchMatcher.isTypo(token, of: $0) }) {
                    tier = .fuzzy
                    continue
                }
                return nil
            }
            return tier
        }
    }

    public static func match(query: String, title: String, context: String = "",
                             includeHighlights: Bool = true) -> SearchMatch?
    {
        guard let tier = PreparedQuery(query).tier(
            foldedTitle: AppMatcher.fold(title),
            foldedContext: AppMatcher.fold(context)
        ) else { return nil }
        return SearchMatch(tier: tier, highlights: includeHighlights ? self.highlights(in: title, query: query) : [])
    }

    public static func highlights(in text: String, query: String) -> [NSRange] {
        var ranges: [NSRange] = []
        for token in self.literalTerm(query).map({ [$0] }) ?? self.tokens(query) {
            var start = text.startIndex
            while start < text.endIndex,
                  let range = text.range(
                      of: token,
                      options: [.caseInsensitive, .diacriticInsensitive],
                      range: start ..< text.endIndex
                  )
            {
                ranges.append(NSRange(range, in: text))
                start = range.upperBound
            }
        }
        return ranges.sorted { $0.location < $1.location }
    }

    /// One insertion, deletion, substitution or adjacent transposition. Longer
    /// words accept a two-edit distance, but short abbreviations never do.
    private static func isTypo(_ query: String, of word: String) -> Bool {
        let left = Array(query), right = Array(word)
        let budget = left.count >= 8 ? 2 : 1
        guard abs(left.count - right.count) <= budget else { return false }
        var previous = Array(0 ... right.count)
        var beforePrevious = previous
        for row in 1 ... left.count {
            var current = [row] + Array(repeating: 0, count: right.count)
            for column in 1 ... right.count {
                current[column] = min(
                    current[column - 1] + 1,
                    previous[column] + 1,
                    previous[column - 1] + (left[row - 1] == right[column - 1] ? 0 : 1)
                )
                if row > 1, column > 1, left[row - 1] == right[column - 2], left[row - 2] == right[column - 1] {
                    current[column] = min(current[column], beforePrevious[column - 2] + 1)
                }
            }
            if current.min() ?? 0 > budget {
                return false
            }
            beforePrevious = previous
            previous = current
        }
        return previous[right.count] <= budget
    }
}

public enum LauncherRanking {
    public static func match(for result: LauncherResult, query: String,
                             aliases: [String: String] = [:]) -> SearchMatch
    {
        switch result {
        case let .app(name, _):
            if let target = aliases[AppMatcher.fold(query)], AppMatcher.fold(name).hasPrefix(AppMatcher.fold(target)) {
                return SearchMatch(tier: .exact)
            }
            if AppMatcher.score(query: query, name: name) == .initials {
                return SearchMatch(tier: .words)
            }
            return SearchMatcher.match(query: query, title: name) ?? SearchMatch(tier: .related)
        case let .file(name, url, _):
            return SearchMatcher.match(query: query, title: name, context: url.deletingLastPathComponent().path)
                ?? SearchMatch(tier: .related)
        case let .clip(item):
            return SearchMatcher.match(
                query: ParsedQuery.parse(query).text,
                title: item.previewText ?? "",
                context: [item.aiTitle, item.linkTitle, item.sourceTitle].compactMap(\.self).joined(separator: " ")
            )
                ?? SearchMatch(tier: .related)
        case let .snippet(item):
            return SearchMatcher
                .match(query: query, title: item.title, context: item.body) ?? SearchMatch(tier: .related)
        case let .systemSetting(name, _):
            return SearchMatcher.match(query: query, title: name) ?? SearchMatch(tier: .related)
        default: return SearchMatch(tier: .related)
        }
    }

    public static func sorted(
        _ results: [LauncherResult],
        query: String,
        aliases: [String: String] = [:],
        usage: [String: Int] = [:]
    ) -> [LauncherResult] {
        results.enumerated().map { index, result in
            (index: index, result: result, priority: self.priority(result, query: query, aliases: aliases))
        }.sorted { left, right in
            if left.priority != right.priority {
                return left.priority < right.priority
            }
            let leftUse = usage[left.result.id, default: 0], rightUse = usage[right.result.id, default: 0]
            if leftUse != rightUse {
                return leftUse > rightUse
            }
            return left.index < right.index
        }.map(\.result)
    }

    private static func priority(_ result: LauncherResult, query: String, aliases: [String: String]) -> Int {
        switch result {
        case .command, .calculation: -1
        case .webSearch: 10
        case .askAI: 11
        case .nowPlaying: 12
        default: self.match(for: result, query: query, aliases: aliases).tier.rawValue
        }
    }
}
