import Foundation

/// Pure keyboard-navigation math for the emoji picker's grid. The picker is a
/// vertical sequence of sections (Recents, Smileys, Animals, …), each laid
/// out in rows of `columns` items (the last row per section may be ragged).
/// `EmojiGridLayout` knows nothing about emoji data or SwiftUI — callers pass
/// a flat index into the concatenation of all sections' items and get back
/// the flat index the arrow keys should land on.
public struct EmojiGridLayout: Sendable {
    private let sectionCounts: [Int]
    private let columns: Int
    private let sectionStarts: [Int]
    private let total: Int

    public init(sectionCounts: [Int], columns: Int) {
        self.sectionCounts = sectionCounts
        self.columns = Swift.max(1, columns)

        var starts: [Int] = []
        starts.reserveCapacity(sectionCounts.count)
        var running = 0
        for count in sectionCounts {
            starts.append(running)
            running += count
        }
        self.sectionStarts = starts
        self.total = running
    }

    public enum Direction: Sendable {
        case up, down, left, right
    }

    /// Which section `index` falls in, and its row-major offset within that
    /// section. `nil` for an out-of-range index (including an empty grid).
    public func sectionAndOffset(of index: Int) -> (section: Int, offset: Int)? {
        guard index >= 0, index < self.total else { return nil }
        for (section, start) in self.sectionStarts.enumerated().reversed() where index >= start {
            return (section, index - start)
        }
        return nil
    }

    /// The flat index reached by moving `direction` from `index`. Returns
    /// `index` unchanged when the move is impossible: out-of-range input, an
    /// empty grid, or a direction that would fall off the grid's edge.
    public func move(from index: Int, _ direction: Direction) -> Int {
        guard self.total > 0, index >= 0, index < self.total else { return index }
        switch direction {
        case .left:
            return Swift.max(0, index - 1)
        case .right:
            return Swift.min(self.total - 1, index + 1)
        case .down:
            return self.moveVertical(from: index, rowDelta: 1)
        case .up:
            return self.moveVertical(from: index, rowDelta: -1)
        }
    }

    /// Shared up/down logic: move to the same column one row away within the
    /// current section, spilling into the neighboring section (skipping any
    /// with zero items) when that row doesn't exist.
    private func moveVertical(from index: Int, rowDelta: Int) -> Int {
        guard let (section, offset) = self.sectionAndOffset(of: index) else { return index }
        let count = self.sectionCounts[section]
        let column = offset % self.columns
        let newRowStart = (offset / self.columns + rowDelta) * self.columns

        if newRowStart >= 0, newRowStart < count {
            let newOffset = Swift.min(newRowStart + column, count - 1)
            return self.sectionStarts[section] + newOffset
        }

        return rowDelta > 0
            ? self.firstRow(afterSection: section, column: column) ?? index
            : self.lastRow(beforeSection: section, column: column) ?? index
    }

    /// First row, same column, of the next non-empty section — clamped if
    /// that section has fewer than `columns` items.
    private func firstRow(afterSection section: Int, column: Int) -> Int? {
        var next = section + 1
        while next < self.sectionCounts.count, self.sectionCounts[next] == 0 {
            next += 1
        }
        guard next < self.sectionCounts.count else { return nil }
        let count = self.sectionCounts[next]
        return self.sectionStarts[next] + Swift.min(column, count - 1)
    }

    /// Last row, same column, of the previous non-empty section — clamped if
    /// that row is ragged.
    private func lastRow(beforeSection section: Int, column: Int) -> Int? {
        var previous = section - 1
        while previous >= 0, self.sectionCounts[previous] == 0 {
            previous -= 1
        }
        guard previous >= 0 else { return nil }
        let count = self.sectionCounts[previous]
        let lastRowStart = (count - 1) / self.columns * self.columns
        return self.sectionStarts[previous] + Swift.min(lastRowStart + column, count - 1)
    }
}
