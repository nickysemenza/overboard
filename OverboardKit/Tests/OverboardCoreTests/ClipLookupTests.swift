import Foundation
@testable import OverboardCore
import Testing

/// The selection rules the App Intents apply. The intents themselves are
/// built by the system and can't be instantiated in a test, so this is the
/// part of them worth covering: which row a listing yields, and what text
/// comes back for it.
struct ClipLookupTests {
    private func item(id: String, isSecret: Bool = false, preview: String? = nil) -> ClipItem {
        let now = Date()
        return ClipItem(
            id: id,
            contentHash: id,
            kind: .text,
            previewText: preview,
            sourceBundleID: nil,
            sourceAppName: nil,
            byteSize: 0,
            isSecret: isSecret,
            createdAt: now,
            lastUsedAt: now,
            updatedAt: now
        )
    }

    @Test func picksTheFirstRowWhenNothingIsSecret() {
        let items = [self.item(id: "a"), self.item(id: "b")]
        #expect(ClipLookup.firstUsable(in: items)?.id == "a")
    }

    @Test func skipsSecretsAtTheTopOfTheListing() {
        let items = [
            self.item(id: "token", isSecret: true),
            self.item(id: "card", isSecret: true),
            self.item(id: "note"),
        ]
        #expect(ClipLookup.firstUsable(in: items)?.id == "note")
    }

    @Test func yieldsNothingWhenEveryRowIsSecret() {
        #expect(ClipLookup.firstUsable(in: [self.item(id: "token", isSecret: true)]) == nil)
        #expect(ClipLookup.firstUsable(in: []) == nil)
    }

    /// The scan limits exist so a run of secrets can't starve the intents.
    @Test func scansMoreRowsThanItNeeds() {
        #expect(ClipLookup.recentScanLimit > 1)
        #expect(ClipLookup.searchScanLimit > 1)
    }

    @Test func resultTextPrefersTheStoredPayload() {
        #expect(ClipLookup.resultText(plainText: "hello", fallback: "hel…") == "hello")
    }

    @Test func resultTextFallsBackToThePreviewWhenOffered() {
        #expect(ClipLookup.resultText(plainText: nil, fallback: "hel…") == "hel…")
    }

    @Test func resultTextIsEmptyWithNothingToReturn() {
        #expect(ClipLookup.resultText(plainText: nil) == "")
        #expect(ClipLookup.resultText(plainText: nil, fallback: nil) == "")
    }
}
