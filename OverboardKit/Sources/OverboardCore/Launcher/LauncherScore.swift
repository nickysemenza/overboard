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

    /// Launching apps is what a launcher is mostly for, so an app gets a
    /// standing lift at every query length, kept under one tier so a better
    /// name match on a file still wins. Shorter queries say less about what
    /// the user wants, so the lift grows as the query shrinks: at "not" a
    /// prefix match on Notes.app beats a file literally named `not.go`.
    static func appBoost(queryLength: Int) -> Double {
        12 + 12 * Double(max(0, 5 - queryLength))
    }

    /// About two tiers: an exact name match in a noise location lands near a
    /// clean words match, so it still beats clean fuzzy and related rows.
    static let noisePenalty = 40.0

    /// Repeats of a name already ranked above lose this much each, up to
    /// `repeatPenaltyCap`: by the second repeat, a little over one tier.
    static let repeatPenalty = 12.0
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

    /// Only evidence of the user's own interest counts here. Depth and a
    /// folder's modified date were tried and dropped: apps write into
    /// shallow folders constantly, which says nothing about the user.
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
        if !info.isDirectory, let modified = info.modifiedAt, modified > .distantPast {
            score += 6 / (1 + max(0, context.now.timeIntervalSince(modified)) / 86400 / 30)
        }
        return score
    }
}
