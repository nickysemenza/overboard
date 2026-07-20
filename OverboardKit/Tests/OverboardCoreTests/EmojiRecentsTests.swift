import Foundation
@testable import OverboardCore
import Testing

struct EmojiRecentsTests {
    // MARK: - Recording

    @Test func recordingIntoEmpty() {
        #expect(EmojiRecents.recording("😀", into: []) == ["😀"])
    }

    @Test func recordingExistingCharacterMovesToFrontWithoutDuplicating() {
        let recents = ["😀", "😂", "🎉"]
        #expect(EmojiRecents.recording("😂", into: recents) == ["😂", "😀", "🎉"])
    }

    @Test func capIsEnforcedAt24() {
        let many = (0 ..< 24).map { String(UnicodeScalar($0 + 65)!) }
        let recents = many.reduce(into: [String]()) { partial, character in
            partial = EmojiRecents.recording(character, into: partial)
        }
        #expect(recents.count == EmojiRecents.cap)

        let withOneMore = EmojiRecents.recording("Z", into: recents)
        #expect(withOneMore.count == EmojiRecents.cap)
        #expect(withOneMore.first == "Z")
        // The oldest entry (first recorded, now at the back) should have been dropped.
        #expect(!withOneMore.contains(many[0]))
    }

    @Test func recordingExistingCharacterAtCapDoesNotDropAnything() {
        let full = (0 ..< 24).map { String(UnicodeScalar($0 + 65)!) }
            .reduce(into: [String]()) { partial, character in
                partial = EmojiRecents.recording(character, into: partial)
            }
        #expect(full.count == EmojiRecents.cap)

        let existing = full[10]
        let updated = EmojiRecents.recording(existing, into: full)
        #expect(updated.count == EmojiRecents.cap)
        #expect(updated.first == existing)
        #expect(Set(updated) == Set(full))
    }

    // MARK: - Pruning

    @Test func prunedRemovesOrphansPreservingOrder() {
        let recents = ["😀", "😂", "🎉", "🥲"]
        let valid: Set = ["😀", "🎉"]
        #expect(EmojiRecents.pruned(recents, validCharacters: valid) == ["😀", "🎉"])
    }

    @Test func prunedWithAllValidIsIdentity() {
        let recents = ["😀", "😂", "🎉"]
        #expect(EmojiRecents.pruned(recents, validCharacters: Set(recents)) == recents)
    }
}
