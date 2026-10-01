import Foundation
import GRDB

public enum SnippetRevisionError: Error, Sendable, Equatable, LocalizedError {
    case exhausted(id: String)

    public var errorDescription: String? {
        "This snippet's revision cannot advance further. Your draft is preserved."
    }
}

public extension ClipStore {
    func snippets() async throws -> [Snippet] {
        try await self.dbWriter.read { db in
            try Snippet
                .filter(sql: "deletedAt IS NULL")
                .order(sql: "title COLLATE NOCASE")
                .fetchAll(db)
        }
    }

    func searchSnippets(_ query: String) async throws -> [Snippet] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return try await self.snippets() }
        return try await self.dbWriter.read { db in
            try Snippet
                .filter(
                    sql: "deletedAt IS NULL AND (title LIKE ? OR body LIKE ?)",
                    arguments: ["%\(trimmed)%", "%\(trimmed)%"]
                )
                .order(sql: "title COLLATE NOCASE")
                .fetchAll(db)
        }
    }

    @discardableResult
    func saveSnippet(_ snippet: Snippet) async throws -> Snippet {
        try await self.persistSnippet(snippet, expectedRevision: nil)
    }

    @discardableResult
    func saveSnippet(_ snippet: Snippet, expectedRevision: Int64) async throws -> Snippet {
        try await self.persistSnippet(snippet, expectedRevision: expectedRevision)
    }

    private func persistSnippet(_ snippet: Snippet, expectedRevision: Int64?) async throws -> Snippet {
        try await self.dbWriter.write { db in
            let current = try Snippet.fetchOne(db, key: snippet.id)
            if let expectedRevision,
               current?.lamport != expectedRevision || current?.deletedAt != nil
            {
                throw SnippetSaveError.revisionConflict(
                    id: snippet.id, expected: expectedRevision, actual: current?.lamport
                )
            }
            var updated = snippet
            updated.createdAt = current?.createdAt ?? snippet.createdAt
            updated.updatedAt = Date()
            updated.lamport = try Self.nextSnippetRevision(after: current?.lamport ?? snippet.lamport, id: snippet.id)
            try updated.save(db)
            return updated
        }
    }

    func deleteSnippet(id: String) async throws {
        try await self.dbWriter.write { db in
            guard let current = try Snippet.fetchOne(db, key: id) else { return }
            let revision = try Self.nextSnippetRevision(after: current.lamport, id: id)
            try db.execute(
                sql: "UPDATE snippet SET deletedAt = ?, updatedAt = ?, lamport = ? WHERE id = ?",
                arguments: [Date(), Date(), revision, id]
            )
        }
    }

    private static func nextSnippetRevision(after revision: Int64, id: String) throws -> Int64 {
        guard revision < Int64.max else { throw SnippetRevisionError.exhausted(id: id) }
        return revision + 1
    }
}
