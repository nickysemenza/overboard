import Foundation

/// Filters and ranks Spotlight file hits by how the query matches the file
/// name. Spotlight's CONTAINS predicate substring-matches anywhere, which
/// floods short queries with junk ("zz" → every fuzz-test file); short
/// queries must match at the start of the name or of a word inside it.
public enum FileNameMatcher {
    /// Substring-anywhere matches are only meaningful once the query is long
    /// enough to be deliberate.
    public static let substringMinLength = 4

    /// Lower ranks sort first; nil drops the hit.
    /// 0 = name prefix, 1 = word prefix, 2 = substring (long queries only).
    public static func rank(name: String, query: String) -> Int? {
        let name = self.fold(name)
        let query = self.fold(query)
        guard !query.isEmpty else { return nil }
        if name.hasPrefix(query) { return 0 }
        let words = name.split { !$0.isLetter && !$0.isNumber }
        if words.contains(where: { $0.hasPrefix(query) }) { return 1 }
        guard query.count >= self.substringMinLength else { return nil }
        return name.contains(query) ? 2 : nil
    }

    private static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
