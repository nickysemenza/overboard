import Foundation

/// Pure matching/ranking for launcher app search. The app list itself comes
/// from AppIndex (OverboardMac); this decides what a query matches and in
/// what order.
public enum AppMatcher {
    /// Match quality, weakest first (synthesized Comparable uses case order).
    public enum Match: Comparable, Sendable {
        case substring
        case initials
        case namePrefix
        case alias
    }

    /// Case- and diacritic-insensitive fold, matching FileNameMatcher and the
    /// FTS index so "cafe" finds "Café" and the whole launcher session treats
    /// accents the same way for apps, files, clips, and emoji (EmojiMatcher
    /// reuses this — public for that).
    public static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// How `query` matches an app `name`, ignoring user aliases.
    /// "sm" matches "Sublime Merge" via initials without any configuration.
    public static func score(query: String, name: String) -> Match? {
        let foldedQuery = self.fold(query)
        let foldedName = self.fold(name)
        guard !foldedQuery.isEmpty, !foldedName.isEmpty else { return nil }
        if foldedName.hasPrefix(foldedQuery) {
            return .namePrefix
        }
        let initials = String(
            foldedName.split(whereSeparator: { $0 == " " || $0 == "-" }).compactMap(\.first)
        )
        if initials.hasPrefix(foldedQuery), initials.count > 1 {
            return .initials
        }
        if foldedName.contains(foldedQuery) {
            return .substring
        }
        return nil
    }

    /// Indices into `names`, best match first, ties broken by shorter then
    /// alphabetical name. `aliases` maps lowercase alias → app-name prefix.
    public static func rank(
        query: String,
        names: [String],
        aliases: [String: String] = [:],
        limit: Int = 5
    ) -> [Int] {
        let foldedQuery = self.fold(query.trimmingCharacters(in: .whitespaces))
        guard !foldedQuery.isEmpty else { return [] }
        let aliasTarget = aliases[foldedQuery].map(self.fold)

        let scored: [(index: Int, match: Match)] = names.enumerated().compactMap { index, name in
            if let target = aliasTarget, self.fold(name).hasPrefix(target) {
                return (index, .alias)
            }
            guard let match = score(query: foldedQuery, name: name) else { return nil }
            return (index, match)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.match != rhs.match {
                    return lhs.match > rhs.match
                }
                let leftName = names[lhs.index], rightName = names[rhs.index]
                if leftName.count != rightName.count {
                    return leftName.count < rightName.count
                }
                return leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
            }
            .prefix(limit)
            .map(\.index)
    }

    /// Parses the Settings text ("sm = Sublime Merge" per line) into a
    /// lowercase alias → target map. Malformed and #-comment lines are
    /// skipped; later lines win on duplicate aliases.
    public static func parseAliases(_ raw: String) -> [String: String] {
        var aliases: [String: String] = [:]
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let alias = self.fold(trimmed[..<separator].trimmingCharacters(in: .whitespaces))
            let target = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !alias.isEmpty, !target.isEmpty else { continue }
            aliases[alias] = target
        }
        return aliases
    }
}
