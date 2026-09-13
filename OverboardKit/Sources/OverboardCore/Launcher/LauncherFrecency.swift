import Foundation

/// Query-independent frequency and recency. A successful selection is the only
/// event counted; merely viewing a row or receiving a provider result is not.
public enum LauncherFrecency {
    public static func sorted(
        _ rows: [LauncherResult],
        counts: [String: Int],
        lastUsed: [String: Double],
        now: Date = .now
    ) -> [LauncherResult] {
        func score(_ row: LauncherResult) -> Double {
            let uses = counts[row.id, default: 0]
            guard uses > 0 else { return 0 }
            let ageDays = max(0, now.timeIntervalSince1970 - lastUsed[row.id, default: 0]) / 86400
            return log2(Double(uses) + 1) / (1 + ageDays / 14)
        }
        return rows.enumerated().sorted { left, right in
            let lhs = score(left.element), rhs = score(right.element)
            if lhs != rhs {
                return lhs > rhs
            }
            return left.offset < right.offset
        }.map(\.element)
    }
}
