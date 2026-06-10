import Foundation
import GRDB

/// A saved text template. Bodies may contain placeholders expanded at paste
/// time — see `SnippetTemplate`.
public struct Snippet: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lamport: Int64
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        title: String,
        body: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lamport: Int64 = 0,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lamport = lamport
        self.deletedAt = deletedAt
    }
}

extension Snippet: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "snippet"
}
