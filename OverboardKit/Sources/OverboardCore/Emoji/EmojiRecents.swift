import Foundation

/// Pure list bookkeeping for the emoji picker's "Recently Used" section.
/// Storage and the actual emoji catalog live elsewhere; this only decides
/// the ordering and membership of the recents list itself.
public enum EmojiRecents {
    /// Maximum number of recents kept; oldest entries fall off the end.
    public static let cap = 24

    /// Returns `recents` with `character` moved (or inserted) at the front,
    /// deduplicated, and capped at `cap`.
    public static func recording(_ character: String, into recents: [String]) -> [String] {
        var updated = recents.filter { $0 != character }
        updated.insert(character, at: 0)
        if updated.count > self.cap {
            updated.removeLast(updated.count - self.cap)
        }
        return updated
    }

    /// Drops characters not present in the catalog (e.g. after dataset
    /// regeneration), preserving the relative order of what remains.
    public static func pruned(_ recents: [String], validCharacters: Set<String>) -> [String] {
        recents.filter { validCharacters.contains($0) }
    }
}
