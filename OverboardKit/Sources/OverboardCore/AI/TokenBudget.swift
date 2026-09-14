import Foundation

/// Trims text to fit a token budget, deferring the actual counting to an
/// injected closure so this stays pure and FoundationModels-free — tests
/// exercise it with a fake counter instead of the real on-device model.
public enum TokenBudget {
    /// Cut-and-recount rounds attempted once the full text is found to be
    /// over budget. Each round narrows the candidate using the previous
    /// round's chars-per-token ratio; the loop always terminates within this
    /// many rounds even if `count` never reports the candidate as fitting.
    private static let maxNarrowingRounds = 3

    /// Returns `text` unchanged when it already fits `budget` tokens (per
    /// `count`). Otherwise repeatedly cuts it — on a `Character` (grapheme)
    /// boundary, so a trim never splits an emoji or a combining CJK cluster —
    /// to an estimated length and re-counts, for at most
    /// `maxNarrowingRounds` rounds, then returns whatever the last round
    /// produced. `budget <= 0` returns the empty string without calling
    /// `count`.
    public static func fit(
        _ text: String,
        budget: Int,
        count: @Sendable (String) async throws -> Int
    ) async throws -> String {
        guard budget > 0 else { return "" }

        var candidate = text
        var tokens = try await count(candidate)

        for _ in 0 ..< self.maxNarrowingRounds {
            guard tokens > budget else { return candidate }

            // 0.95 leaves headroom: the chars-per-token ratio is only an
            // approximation (tokenizers don't split on character
            // boundaries), so aiming exactly at `budget` tends to overshoot.
            let ratio = Double(budget) / Double(tokens) * 0.95
            let charBudget = max(0, Int(Double(candidate.count) * ratio))
            candidate = String(candidate.prefix(charBudget))
            tokens = try await count(candidate)
        }
        return candidate
    }
}
