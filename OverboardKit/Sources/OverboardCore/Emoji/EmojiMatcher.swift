import Foundation

/// Pure matching/ranking for emoji picker search, same shape as AppMatcher:
/// the catalog supplies the emoji, this decides what a query matches and in
/// what order.
public enum EmojiMatcher {
    /// Match quality, weakest first (synthesized Comparable uses case order).
    public enum Match: Comparable, Sendable {
        case keywordSubstring
        case keywordPrefix
        case nameSubstring
        case nameWordPrefix
        case namePrefix
        case nameExact
    }

    /// How `query` matches one emoji's name/keywords, or nil for no match.
    /// Query and fields are folded so "café" and "cafe" behave the same.
    public static func score(query: String, emoji: Emoji) -> Match? {
        let q = AppMatcher.fold(query)
        guard !q.isEmpty else { return nil }
        let name = AppMatcher.fold(emoji.name)
        // Exact beats prefix so "fire" selects 🔥, not whichever fire-prefixed
        // name (firefighter) happens to come first in catalog order.
        if name == q {
            return .nameExact
        }
        if name.hasPrefix(q) {
            return .namePrefix
        }
        if name.split(separator: " ").dropFirst().contains(where: { $0.hasPrefix(q) }) {
            return .nameWordPrefix
        }
        if name.contains(q) {
            return .nameSubstring
        }
        let keywords = emoji.keywords.lazy.map { AppMatcher.fold($0) }
        if keywords.contains(where: { $0.hasPrefix(q) }) {
            return .keywordPrefix
        }
        if keywords.contains(where: { $0.contains(q) }) {
            return .keywordSubstring
        }
        return nil
    }

    /// Matching emoji, best first; ties keep catalog (CLDR display) order so
    /// results are stable and the canonical emoji for a word leads its variants.
    public static func rank(query: String, in emoji: [Emoji], limit: Int = 120) -> [Emoji] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }

        let scored: [(index: Int, match: Match)] = emoji.enumerated().compactMap { index, candidate in
            guard let match = score(query: q, emoji: candidate) else { return nil }
            return (index, match)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.match != rhs.match {
                    return lhs.match > rhs.match
                }
                return lhs.index < rhs.index
            }
            .prefix(limit)
            .map { emoji[$0.index] }
    }
}
