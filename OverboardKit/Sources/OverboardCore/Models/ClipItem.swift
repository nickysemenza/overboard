import Foundation
import GRDB

public struct ClipItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var contentHash: String
    public var kind: ItemKind
    public var previewText: String?
    public var sourceBundleID: String?
    public var sourceAppName: String?
    public var byteSize: Int
    public var isPinned: Bool
    public var isSecret: Bool
    public var useCount: Int
    public var createdAt: Date
    public var lastUsedAt: Date
    public var updatedAt: Date
    public var lamport: Int64
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        contentHash: String,
        kind: ItemKind,
        previewText: String?,
        sourceBundleID: String?,
        sourceAppName: String?,
        byteSize: Int,
        isPinned: Bool = false,
        isSecret: Bool = false,
        useCount: Int = 1,
        createdAt: Date,
        lastUsedAt: Date,
        updatedAt: Date,
        lamport: Int64 = 0,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.contentHash = contentHash
        self.kind = kind
        self.previewText = previewText
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.byteSize = byteSize
        self.isPinned = isPinned
        self.isSecret = isSecret
        self.useCount = useCount
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.updatedAt = updatedAt
        self.lamport = lamport
        self.deletedAt = deletedAt
    }
}

extension ClipItem: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "item"
}
