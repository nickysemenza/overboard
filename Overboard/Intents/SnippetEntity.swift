import AppIntents
import OverboardCore

/// An `AppEntity` wrapper around a saved `Snippet`, so Shortcuts/Siri can pick
/// one by name. Snippets are user-authored text templates (no secrets, no
/// TTL), unlike `ClipItem`, which deliberately stays out of App Intents.
struct SnippetEntity: AppEntity {
    let id: String
    let title: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Snippet"
    static let defaultQuery = SnippetQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(self.title)")
    }
}

/// Backs `SnippetEntity` lookups with `ClipStore`'s existing snippet listing
/// and search, so Shortcuts' picker and voice matching go through the same
/// data the Snippets manager window uses.
struct SnippetQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SnippetEntity] {
        let snippets = try await IntentDependencies.current.store.snippets()
        return snippets
            .filter { identifiers.contains($0.id) }
            .map { SnippetEntity(id: $0.id, title: $0.title) }
    }

    func entities(matching string: String) async throws -> [SnippetEntity] {
        let snippets = try await IntentDependencies.current.store.searchSnippets(string)
        return snippets.map { SnippetEntity(id: $0.id, title: $0.title) }
    }

    func suggestedEntities() async throws -> [SnippetEntity] {
        let snippets = try await IntentDependencies.current.store.snippets()
        return snippets.prefix(10).map { SnippetEntity(id: $0.id, title: $0.title) }
    }
}
