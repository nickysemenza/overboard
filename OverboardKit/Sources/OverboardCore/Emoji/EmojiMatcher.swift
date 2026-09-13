import Foundation
#if DEBUG
    import Playgrounds
#endif

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
        let foldedQuery = AppMatcher.fold(query)
        guard !foldedQuery.isEmpty else { return nil }
        let name = AppMatcher.fold(emoji.name)
        // Exact beats prefix so "fire" selects 🔥, not whichever fire-prefixed
        // name (firefighter) happens to come first in catalog order.
        if name == foldedQuery {
            return .nameExact
        }
        if name.hasPrefix(foldedQuery) {
            return .namePrefix
        }
        if name.split(separator: " ").dropFirst().contains(where: { $0.hasPrefix(foldedQuery) }) {
            return .nameWordPrefix
        }
        if name.contains(foldedQuery) {
            return .nameSubstring
        }
        let keywords = emoji.keywords.lazy.map { AppMatcher.fold($0) }
        if keywords.contains(where: { $0.hasPrefix(foldedQuery) }) {
            return .keywordPrefix
        }
        if keywords.contains(where: { $0.contains(foldedQuery) }) {
            return .keywordSubstring
        }
        return nil
    }

    /// Matching emoji, best first; ties keep catalog (CLDR display) order so
    /// results are stable and the canonical emoji for a word leads its variants.
    public static func rank(query: String, in emoji: [Emoji], limit: Int = 120) -> [Emoji] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
        guard !trimmedQuery.isEmpty else { return [] }

        let scored: [(index: Int, match: Match)] = emoji.enumerated().compactMap { index, candidate in
            guard let match = score(query: trimmedQuery, emoji: candidate) else { return nil }
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

#if DEBUG
    #Playground("Emoji ranking") {
        let sample = [
            Emoji(character: "🔥", name: "fire", keywords: ["hot", "flame"], category: .objects, version: 1),
            Emoji(character: "🚒", name: "fire engine", keywords: ["truck"], category: .travel, version: 1),
            Emoji(character: "🧑‍🚒", name: "firefighter", keywords: ["rescue"], category: .people, version: 1),
            Emoji(character: "😀", name: "grinning face", keywords: ["smile", "happy"], category: .smileys, version: 1),
            Emoji(character: "🐶", name: "dog face", keywords: ["puppy", "pet"], category: .animals, version: 1),
        ]
        for query in ["fire", "dog", "zzz"] {
            print(query, "→", EmojiMatcher.rank(query: query, in: sample).map(\.character))
        }

        print("exact:", EmojiMatcher.score(query: "fire", emoji: sample[0]) as Any)
        print("prefix:", EmojiMatcher.score(query: "fire", emoji: sample[1]) as Any)
        print("fuzzy:", EmojiMatcher.score(query: "upp", emoji: sample[4]) as Any)
    }
#endif
