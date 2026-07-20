import Foundation
@testable import OverboardCore
import Testing

/// Integrity checks over the bundled emoji.json — these guard dataset
/// regeneration (scripts/generate-emoji-data.swift) as much as the loader.
struct EmojiCatalogTests {
    private let catalog = EmojiCatalog.load()

    @Test func loadsAPlausibleDataset() {
        #expect((1700 ... 2100).contains(self.catalog.all.count))
        // Every category should be represented in a full dataset.
        #expect(self.catalog.byCategory.count == EmojiCategory.allCases.count)
    }

    @Test func charactersAreUniqueAndFieldsNonEmpty() {
        #expect(Set(self.catalog.all.map(\.character)).count == self.catalog.all.count)
        #expect(self.catalog.all.allSatisfy { !$0.character.isEmpty && !$0.name.isEmpty })
        #expect(self.catalog.all.allSatisfy { $0.version > 0 })
    }

    @Test func skinToneVariantsAreExcluded() {
        // v1 ships base emoji only; the generator drops U+1F3FB…U+1F3FF sequences.
        let modifiers = Set<UInt32>(0x1F3FB ... 0x1F3FF)
        let withTone = self.catalog.all.filter { emoji in
            emoji.character.unicodeScalars.contains { modifiers.contains($0.value) }
        }
        #expect(withTone.isEmpty)
    }

    @Test func everyEmojiIsFindableByItsOwnName() {
        // The search path must be able to reach the whole catalog. Use a
        // per-emoji score check (rank truncates common-word queries like "cat"
        // to its limit, which would falsely fail the long tail).
        let unfindable = self.catalog.all.filter { emoji in
            EmojiMatcher.score(query: emoji.name, emoji: emoji) == nil
        }
        #expect(unfindable.isEmpty, "\(unfindable.prefix(5).map(\.name))")
    }

    @Test func byCategoryPreservesDisplayOrder() {
        for (category, members) in self.catalog.byCategory {
            let expected = self.catalog.all.filter { $0.category == category }
            #expect(members == expected)
        }
    }

    @Test func fireIsPresentWithKeywords() {
        let fire = self.catalog.byCharacter["🔥"]
        #expect(fire?.name == "fire")
        #expect(fire?.category == .travel || fire?.category == .objects || fire?.category == .animals)
    }

    @Test func renderGateDropsWholeVersionBuckets() {
        let newest = self.catalog.all.map(\.version).max() ?? 0
        let gated = EmojiCatalog.load(isRenderable: { emoji in
            // Simulate an OS that can't draw the newest emoji version.
            self.catalog.byCharacter[emoji]?.version != newest
        })
        #expect(gated.all.allSatisfy { $0.version != newest })
        #expect(!gated.all.isEmpty)
    }
}
