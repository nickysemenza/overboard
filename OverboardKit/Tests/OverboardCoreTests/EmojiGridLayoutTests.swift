import Foundation
@testable import OverboardCore
import Testing

struct EmojiGridLayoutTests {
    // MARK: - Left / right

    @Test func leftRightWithinARow() {
        let layout = EmojiGridLayout(sectionCounts: [10], columns: 5)
        #expect(layout.move(from: 2, .right) == 3)
        #expect(layout.move(from: 3, .left) == 2)
    }

    @Test func rightCrossesSectionBoundary() {
        let layout = EmojiGridLayout(sectionCounts: [3, 4], columns: 5)
        #expect(layout.move(from: 2, .right) == 3)
    }

    @Test func leftCrossesSectionBoundary() {
        let layout = EmojiGridLayout(sectionCounts: [3, 4], columns: 5)
        #expect(layout.move(from: 3, .left) == 2)
    }

    @Test func leftRightClampAtFlatEnds() {
        let layout = EmojiGridLayout(sectionCounts: [3, 4], columns: 5)
        #expect(layout.move(from: 0, .left) == 0)
        #expect(layout.move(from: 6, .right) == 6)
    }

    // MARK: - Down

    @Test func downWithinASectionFullRows() {
        // 2 rows of 4 in a section of 8.
        let layout = EmojiGridLayout(sectionCounts: [8], columns: 4)
        #expect(layout.move(from: 1, .down) == 5)
    }

    @Test func downOntoRaggedLastRowClampsColumn() {
        // Section of 6 items, columns 4: rows are [0,1,2,3] and [4,5].
        let layout = EmojiGridLayout(sectionCounts: [6], columns: 4)
        #expect(layout.move(from: 3, .down) == 5)
    }

    @Test func downFromLastRowCrossesIntoNextSectionSameColumn() {
        // Section 0 has one ragged row [0,1,2]; section 1 starts at flat index 3.
        let layout = EmojiGridLayout(sectionCounts: [3, 8], columns: 4)
        #expect(layout.move(from: 1, .down) == 3 + 1)
    }

    @Test func downFromLastSectionLastRowIsNoOp() {
        let layout = EmojiGridLayout(sectionCounts: [3, 5], columns: 4)
        let lastIndex = 3 + 4 // second row, column 0, of the final section
        #expect(layout.move(from: lastIndex, .down) == lastIndex)
    }

    // MARK: - Up

    @Test func upMirrorsDownWithinSection() {
        let layout = EmojiGridLayout(sectionCounts: [8], columns: 4)
        #expect(layout.move(from: 5, .up) == 1)
    }

    @Test func upFromFirstRowEntersPreviousSectionLastRow() {
        // Section 0: 8 items in 2 full rows of 4. Section 1 starts at 8.
        let layout = EmojiGridLayout(sectionCounts: [8, 3], columns: 4)
        #expect(layout.move(from: 8, .up) == 4)
    }

    @Test func upClampsOntoPreviousSectionRaggedLastRow() {
        // Section 0: 6 items, last row ragged at columns [4,5]. Section 1 starts at 6.
        let layout = EmojiGridLayout(sectionCounts: [6, 4], columns: 4)
        #expect(layout.move(from: 6 + 3, .up) == 5) // column 3 clamps to last item (offset 5)
    }

    @Test func upFromFirstSectionFirstRowIsNoOp() {
        let layout = EmojiGridLayout(sectionCounts: [8], columns: 4)
        #expect(layout.move(from: 2, .up) == 2)
    }

    // MARK: - Degenerate grids

    @Test func singleSectionSingleRow() {
        let layout = EmojiGridLayout(sectionCounts: [3], columns: 5)
        #expect(layout.move(from: 1, .up) == 1)
        #expect(layout.move(from: 1, .down) == 1)
        #expect(layout.move(from: 0, .left) == 0)
        #expect(layout.move(from: 2, .right) == 2)
    }

    @Test func zeroCountSectionIsSkippedWhenCrossing() {
        // Section 1 is empty; down from section 0's last row should land in section 2.
        let layout = EmojiGridLayout(sectionCounts: [3, 0, 5], columns: 4)
        #expect(layout.move(from: 1, .down) == 3 + 1)
        // And left/right shouldn't ever land inside the empty section.
        #expect(layout.move(from: 2, .right) == 3)
        #expect(layout.move(from: 3, .left) == 2)
    }

    @Test func outOfRangeIndexReturnsUnchanged() {
        let layout = EmojiGridLayout(sectionCounts: [3, 4], columns: 4)
        #expect(layout.move(from: -1, .right) == -1)
        #expect(layout.move(from: 99, .down) == 99)
    }

    @Test func emptyCountsReturnsIndexUnchanged() {
        let layout = EmojiGridLayout(sectionCounts: [], columns: 4)
        #expect(layout.move(from: 0, .right) == 0)
    }

    @Test func columnsOneBehavesLikeAFlatListWithinSection() {
        let layout = EmojiGridLayout(sectionCounts: [4], columns: 1)
        #expect(layout.move(from: 0, .down) == 1)
        #expect(layout.move(from: 1, .up) == 0)
    }

    @Test func degenerateColumnsCountIsTreatedAsOne() {
        let layout = EmojiGridLayout(sectionCounts: [4], columns: 0)
        #expect(layout.move(from: 0, .down) == 1)
    }

    // MARK: - sectionAndOffset

    @Test func sectionAndOffsetLocatesFlatIndices() {
        let layout = EmojiGridLayout(sectionCounts: [3, 0, 5], columns: 4)
        #expect(layout.sectionAndOffset(of: 0)?.section == 0)
        #expect(layout.sectionAndOffset(of: 2)?.offset == 2)
        #expect(layout.sectionAndOffset(of: 3)?.section == 2)
        #expect(layout.sectionAndOffset(of: 3)?.offset == 0)
        #expect(layout.sectionAndOffset(of: -1) == nil)
        #expect(layout.sectionAndOffset(of: 8) == nil)
    }
}
