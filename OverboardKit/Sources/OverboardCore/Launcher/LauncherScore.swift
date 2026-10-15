import Foundation

/// The blended judgement behind both `LauncherRanking.sorted` and
/// `FileNameIndex.rank` (docs/adr/0001-blended-launcher-ranking.md). Match
/// tier weighs most, one tier apart being `tierStep` points; everything else
/// nudges a row toward or away from being the user's own.
///
/// Exact-query picks and the fixed first/last kinds sit outside this score —
/// see `LauncherRanking.priority`.
public enum LauncherScore {
    static let tierStep = 20.0

    /// Short queries are usually someone typing toward an app, so apps get a
    /// lift that fades out by five characters: at "not" it is enough for a
    /// prefix match on Notes.app to beat a file literally named `not.go`.
    static func appBoost(queryLength: Int) -> Double {
        12 * Double(max(0, 5 - queryLength))
    }

    /// About two tiers: an exact name match in a noise location lands near a
    /// clean words match, so it still beats clean fuzzy and related rows.
    static let noisePenalty = 40.0

    /// Repeats of a name already ranked above lose this much each, up to
    /// `repeatPenaltyCap`.
    static let repeatPenalty = 10.0
    static let repeatPenaltyCap = 40.0

    public static func value(
        for result: LauncherResult,
        tier: SearchMatch.Tier,
        query: String,
        context: LauncherSearchContext
    ) -> Double {
        var score = Double(SearchMatch.Tier.related.rawValue - tier.rawValue) * self.tierStep
        // Bounded below one tier: general frecency alone can't lift a words
        // match over a prefix match.
        score += min(12, 3 * context.frecency(result.id))
        if let carried = context.carried[result.id] {
            score += min(18, 8 * log2(1 + carried))
        }
        switch result {
        case .app:
            score += self.appBoost(queryLength: query.trimmingCharacters(in: .whitespacesAndNewlines).count)
        case let .file(_, url, info):
            score += self.fileAdjustment(url: url, info: info, context: context)
        default: break
        }
        return score
    }

    private static func fileAdjustment(url: URL, info: FileSearchInfo, context: LauncherSearchContext) -> Double {
        var score = 0.0
        // Whatever its folder looks like, a file the user opened recently or
        // picked a neighbour of is evidently theirs.
        let openedRecently = info.lastOpenedAt.map { context.now.timeIntervalSince($0) < 30 * 86400 } ?? false
        if !openedRecently, context.noiseRules.isNoise(path: url.path, detected: info.isNoise),
           !context.pickedFolders.contains(url.deletingLastPathComponent().path)
        {
            score -= self.noisePenalty
        }
        if let opened = info.lastOpenedAt {
            score += 12 / (1 + max(0, context.now.timeIntervalSince(opened)) / 86400 / 14)
        }
        if let modified = info.modifiedAt, modified > .distantPast {
            score += 6 / (1 + max(0, context.now.timeIntervalSince(modified)) / 86400 / 30)
        }
        if let depth = info.depth {
            score += max(0, 4 - Double(depth - 1))
        }
        return score
    }
}
