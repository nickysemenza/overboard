import Foundation
@testable import OverboardCore
import Testing

/// The single kind → symbol/label/tint map that replaced four hand-maintained
/// copies. Every case must carry a usable symbol and label, or a surface that
/// reads the map renders a blank slot.
struct ItemKindPresentationTests {
    @Test func everyKindHasASymbolAndLabel() {
        for kind in ItemKind.allCases {
            #expect(!kind.symbolName.isEmpty, "\(kind) has no SF Symbol")
            #expect(!kind.displayName.isEmpty, "\(kind) has no display name")
        }
    }

    @Test func symbolsAndLabelsAreDistinctPerKind() {
        #expect(Set(ItemKind.allCases.map(\.symbolName)).count == ItemKind.allCases.count)
        #expect(Set(ItemKind.allCases.map(\.displayName)).count == ItemKind.allCases.count)
    }

    @Test func countLabelsAgreeWithTheirCount() {
        #expect(ItemKind.link.countLabel(0) == "0 links")
        #expect(ItemKind.link.countLabel(1) == "1 link")
        #expect(ItemKind.link.countLabel(2) == "2 links")
        #expect(ItemKind.file.countLabel(1) == "1 file")
        #expect(ItemKind.image.countLabel(3) == "3 images")
        #expect(ItemKind.color.countLabel(1) == "1 color")
    }

    /// "text" is the one mass noun in the ramp; it must not gain an "s".
    @Test func textNeverPluralizes() {
        #expect(ItemKind.text.countLabel(1) == "1 text")
        #expect(ItemKind.text.countLabel(812) == "812 text")
    }
}

struct CountPhraseTests {
    @Test func inflectsRegularNouns() {
        #expect(CountPhrase.string(0, of: "link") == "0 links")
        #expect(CountPhrase.string(1, of: "link") == "1 link")
        #expect(CountPhrase.string(2, of: "link") == "2 links")
    }

    @Test func groupsLargeCounts() {
        #expect(CountPhrase.string(1240, of: "character") == "1,240 characters")
    }
}

struct LibraryStatsSubtitleTests {
    private func stats(total: Int, kinds: [(ItemKind, Int)]) -> LibraryStats {
        LibraryStats(
            total: total,
            byKind: kinds.map { LibraryStats.KindCount(kind: $0.0, count: $0.1) },
            bySource: [],
            bytesByKind: []
        )
    }

    @Test func summarizesTotalAndTopThreeKinds() {
        let subtitle = self.stats(
            total: 1234,
            kinds: [(.text, 812), (.link, 96), (.image, 12), (.file, 4)]
        ).subtitle
        #expect(subtitle == "1,234 items · 812 text · 96 links · 12 images")
    }

    @Test func singularCountsAgree() {
        #expect(self.stats(total: 1, kinds: [(.link, 1)]).subtitle == "1 item · 1 link")
    }

    @Test func emptyLibraryIsJustTheTotal() {
        #expect(self.stats(total: 0, kinds: []).subtitle == "0 items")
    }
}
