import Foundation
import OverboardCore
@testable import OverboardUI
import Testing

/// `DrawerViewModel.stripEntries(for:)` is the pure function that decides
/// which cards get the "ranked above a newer item" hint (see the frecency
/// doc comment on `ClipStore.frecencyOrderSQL`); these cases exercise it
/// directly, without a `ClipStore`.
struct StripEntryTests {
    private func item(id: String, useCount: Int, hoursAgo: Double, pinned: Bool = false) -> ClipItem {
        let when = Date().addingTimeInterval(-hoursAgo * 3600)
        return ClipItem(
            id: id, contentHash: id, kind: .text, previewText: id,
            sourceBundleID: nil, sourceAppName: nil, byteSize: 1,
            isPinned: pinned, useCount: useCount,
            createdAt: when, lastUsedAt: when, updatedAt: when
        )
    }

    @Test func olderFrequentItemAboveNewerOneIsFlaggedNotTheNewerOne() {
        let older = self.item(id: "older", useCount: 8, hoursAgo: 2)
        let newer = self.item(id: "newer", useCount: 1, hoursAgo: 0)
        let entries = DrawerViewModel.stripEntries(for: [older, newer])
        #expect(entries.map(\.rankedAboveNewer) == [true, false])
    }

    @Test func pinnedItemAboveNewerOneIsNeverFlagged() {
        let pinned = self.item(id: "pinned", useCount: 1, hoursAgo: 100, pinned: true)
        let newer = self.item(id: "newer", useCount: 1, hoursAgo: 0)
        let entries = DrawerViewModel.stripEntries(for: [pinned, newer])
        #expect(entries.map(\.rankedAboveNewer) == [false, false])
    }

    @Test func strictlyRecencyOrderedListIsNeverFlagged() {
        let newest = self.item(id: "newest", useCount: 1, hoursAgo: 0)
        let middle = self.item(id: "middle", useCount: 1, hoursAgo: 1)
        let oldest = self.item(id: "oldest", useCount: 1, hoursAgo: 2)
        let entries = DrawerViewModel.stripEntries(for: [newest, middle, oldest])
        #expect(entries.map(\.rankedAboveNewer) == [false, false, false])
    }

    @Test func singleItemIsNeverFlagged() {
        let only = self.item(id: "only", useCount: 4, hoursAgo: 0)
        let entries = DrawerViewModel.stripEntries(for: [only])
        #expect(entries.map(\.rankedAboveNewer) == [false])
    }

    @Test func stripEntryIDMatchesItemID() {
        let solo = self.item(id: "solo-id", useCount: 1, hoursAgo: 0)
        let entries = DrawerViewModel.stripEntries(for: [solo])
        #expect(entries.map(\.id) == ["solo-id"])
    }
}
