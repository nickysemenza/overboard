import Foundation
@testable import OverboardCore
import Testing

struct EmojiMatcherTests {
    private func emoji(
        _ character: String,
        name: String,
        keywords: [String] = [],
        category: EmojiCategory = .objects
    ) -> Emoji {
        Emoji(character: character, name: name, keywords: keywords, category: category, version: 1)
    }

    // MARK: - Scoring

    @Test func nameExactBeatsPrefixWordPrefixAndSubstring() {
        let fire = self.emoji("🔥", name: "fire")
        let engine = self.emoji("🚒", name: "fire engine")
        let campfire = self.emoji("🏕️", name: "camping fire site")
        let bonfire = self.emoji("🎇", name: "bonfire")
        #expect(EmojiMatcher.score(query: "fire", emoji: fire) == .nameExact)
        #expect(EmojiMatcher.score(query: "fire", emoji: engine) == .namePrefix)
        #expect(EmojiMatcher.score(query: "fire", emoji: campfire) == .nameWordPrefix)
        #expect(EmojiMatcher.score(query: "fire", emoji: bonfire) == .nameSubstring)
    }

    /// The live regression this tier exists for: "firefighter" (People & Body)
    /// precedes 🔥 (Travel & Places) in catalog order, so without the exact
    /// tier both score namePrefix and the tie-break picks the firefighter.
    @Test func exactNameWinsOverEarlierCatalogPrefixMatch() {
        let firefighter = self.emoji("🧑‍🚒", name: "firefighter", category: .people)
        let fire = self.emoji("🔥", name: "fire", category: .travel)
        let ranked = EmojiMatcher.rank(query: "fire", in: [firefighter, fire]).map(\.character)
        #expect(ranked == ["🔥", "🧑‍🚒"])
    }

    @Test func keywordMatchesRankBelowNameMatches() {
        let flame = self.emoji("🔥", name: "fire", keywords: ["flame", "hot"])
        #expect(EmojiMatcher.score(query: "flame", emoji: flame) == .keywordPrefix)
        #expect(EmojiMatcher.score(query: "lam", emoji: flame) == .keywordSubstring)
        #expect(EmojiMatcher.score(query: "xyz", emoji: flame) == nil)
        #expect(EmojiMatcher.Match.namePrefix > .keywordPrefix)
        #expect(EmojiMatcher.Match.keywordPrefix > .keywordSubstring)
    }

    @Test func matchingFoldsCaseAndDiacritics() {
        let cafe = self.emoji("☕", name: "café", keywords: ["crème"])
        #expect(EmojiMatcher.score(query: "CAFE", emoji: cafe) == .nameExact)
        #expect(EmojiMatcher.score(query: "creme", emoji: cafe) == .keywordPrefix)
    }

    @Test func emptyQueryMatchesNothing() {
        let fire = self.emoji("🔥", name: "fire")
        #expect(EmojiMatcher.score(query: "", emoji: fire) == nil)
        #expect(EmojiMatcher.score(query: "   ", emoji: fire) == nil)
        #expect(EmojiMatcher.rank(query: "  ", in: [fire]).isEmpty)
    }

    // MARK: - Ranking

    @Test func rankOrdersByMatchQualityThenCatalogOrder() {
        let candidates = [
            self.emoji("🎇", name: "sparkler fire"), // word prefix
            self.emoji("🚒", name: "fire engine"), // name prefix, later in catalog
            self.emoji("🔥", name: "fire"), // name prefix
            self.emoji("💡", name: "light bulb", keywords: ["fireless"]), // keyword prefix
        ]
        let ranked = EmojiMatcher.rank(query: "fire", in: candidates).map(\.character)
        // Exact name first, then prefix, then word prefix, then keyword.
        #expect(ranked == ["🔥", "🚒", "🎇", "💡"])
    }

    @Test func rankHonorsLimit() {
        let many = (0 ..< 50).map { self.emoji("e\($0)", name: "fish \($0)") }
        #expect(EmojiMatcher.rank(query: "fish", in: many, limit: 10).count == 10)
    }
}
