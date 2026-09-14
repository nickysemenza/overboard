import Foundation

/// Query-independent frequency and recency. A successful selection is the only
/// event counted; merely viewing a row or receiving a provider result is not.
public enum LauncherFrecency {
    /// The frecency formula, shared with `LauncherRanking.sorted`'s
    /// within-tier frecency tiebreak so the empty-launcher suggestions and
    /// mid-query ranking agree on what "used often and recently" means.
    public static func score(
        id: String,
        counts: [String: Int],
        lastUsed: [String: Double],
        now: Date = .now
    ) -> Double {
        let uses = counts[id, default: 0]
        guard uses > 0 else { return 0 }
        let ageDays = max(0, now.timeIntervalSince1970 - lastUsed[id, default: 0]) / 86400
        return log2(Double(uses) + 1) / (1 + ageDays / 14)
    }

    public static func sorted(
        _ rows: [LauncherResult],
        counts: [String: Int],
        lastUsed: [String: Double],
        now: Date = .now
    ) -> [LauncherResult] {
        rows.enumerated().sorted { left, right in
            let lhs = self.score(id: left.element.id, counts: counts, lastUsed: lastUsed, now: now)
            let rhs = self.score(id: right.element.id, counts: counts, lastUsed: lastUsed, now: now)
            if lhs != rhs {
                return lhs > rhs
            }
            return left.offset < right.offset
        }.map(\.element)
    }
}
