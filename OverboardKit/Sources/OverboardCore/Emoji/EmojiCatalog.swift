import Foundation

/// One pickable emoji from the bundled dataset.
public struct Emoji: Sendable, Hashable, Identifiable {
    /// The emoji string itself — also the stable identity and what gets pasted.
    public let character: String
    /// Lowercased CLDR name, e.g. "fire".
    public let name: String
    /// Search keywords (CLDR annotations + shortcodes), lowercased.
    public let keywords: [String]
    public let category: EmojiCategory
    /// Emoji spec version (15.1, 16, …) — the OS-support gate.
    public let version: Double

    public var id: String {
        self.character
    }

    public init(character: String, name: String, keywords: [String], category: EmojiCategory, version: Double) {
        self.character = character
        self.name = name
        self.keywords = keywords
        self.category = category
        self.version = version
    }
}

/// Display categories, in Unicode/CLDR presentation order (which is also the
/// order the picker shows sections in).
public enum EmojiCategory: String, Codable, CaseIterable, Sendable {
    case smileys, people, animals, food, travel, activities, objects, symbols, flags

    /// Section header title, matching the familiar Unicode group names.
    public var title: String {
        switch self {
        case .smileys: "Smileys & Emotion"
        case .people: "People & Body"
        case .animals: "Animals & Nature"
        case .food: "Food & Drink"
        case .travel: "Travel & Places"
        case .activities: "Activities"
        case .objects: "Objects"
        case .symbols: "Symbols"
        case .flags: "Flags"
        }
    }
}

/// The bundled emoji dataset (scripts/generate-emoji-data.swift output),
/// decoded once and grouped by category in display order.
public struct EmojiCatalog: Sendable {
    /// Every emoji, in CLDR display order.
    public let all: [Emoji]
    /// Categories in `EmojiCategory.allCases` order, empty ones dropped.
    public let byCategory: [(category: EmojiCategory, emoji: [Emoji])]
    /// O(1) lookup for recents pruning and validation.
    public let byCharacter: [String: Emoji]

    /// Loads the bundled dataset. `isRenderable` gates newer emoji the running
    /// OS can't draw: entries are bucketed by spec version and a bucket is
    /// dropped when its representatives fail the check (checking a few per
    /// bucket rather than one guards against sequence-specific quirks). The
    /// default accepts everything, which keeps OverboardCore free of CoreText —
    /// the real check lives in OverboardMac.
    public static func load(isRenderable: (String) -> Bool = { _ in true }) -> EmojiCatalog {
        guard let url = Bundle.module.url(forResource: "emoji", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else {
            assertionFailure("bundled emoji.json missing or malformed")
            return EmojiCatalog(all: [])
        }

        let decoded = entries.compactMap(\.emoji)
        let unsupported = Self.unsupportedVersions(in: decoded, isRenderable: isRenderable)
        return EmojiCatalog(all: decoded.filter { !unsupported.contains($0.version) })
    }

    /// Public so tests and previews can build small fixed catalogs; the app
    /// always goes through `load`.
    public init(all: [Emoji]) {
        self.all = all
        self.byCategory = EmojiCategory.allCases.compactMap { category in
            let members = all.filter { $0.category == category }
            return members.isEmpty ? nil : (category, members)
        }
        self.byCharacter = Dictionary(all.map { ($0.character, $0) }) { first, _ in first }
    }

    /// Spec versions whose emoji the OS can't render, decided by sampling up to
    /// three representatives per version — dropping a whole bucket on any
    /// failure is deliberately conservative (better to hide a renderable emoji
    /// than to show tofu).
    private static func unsupportedVersions(
        in emoji: [Emoji],
        isRenderable: (String) -> Bool
    ) -> Set<Double> {
        let buckets = Dictionary(grouping: emoji, by: \.version)
        var unsupported: Set<Double> = []
        for (version, members) in buckets
            where members.prefix(3).contains(where: { !isRenderable($0.character) })
        {
            unsupported.insert(version)
        }
        return unsupported
    }

    /// Compact on-disk schema — see scripts/generate-emoji-data.swift.
    private struct Entry: Decodable {
        let e: String
        let n: String
        let k: [String]
        let c: String
        let v: Double

        /// nil for unknown category raw values, so a dataset regenerated
        /// against a newer emojibase can't crash an older app build.
        var emoji: Emoji? {
            guard let category = EmojiCategory(rawValue: self.c) else { return nil }
            return Emoji(character: self.e, name: self.n, keywords: self.k, category: category, version: self.v)
        }
    }
}
