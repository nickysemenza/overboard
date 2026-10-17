import Foundation
import GRDB

// MARK: - Recopy dedupe

extension ClipStore {
    /// The recopy fast path: if live content with this hash exists, bump it and
    /// return it; nil means "new content, carry on". A cheap indexed read gates
    /// the write so the (far more common) new-content case doesn't take the
    /// writer lock twice.
    func bumpLiveItem(
        contentHash: String, snapshot: PasteboardSnapshot, isSecret: Bool
    ) async throws -> ClipItem? {
        let exists = try await self.dbWriter.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM item WHERE contentHash = ? AND deletedAt IS NULL)",
                arguments: [contentHash]
            ) ?? false
        }
        guard exists else { return nil }
        return try await self.writeCancellable { db in
            try snapshot.admission?.check()
            let bumped = try Self.bumpExisting(
                db, contentHash: contentHash, now: snapshot.capturedAt, isSecret: isSecret
            )
            try snapshot.admission?.check()
            return bumped
        }
    }

    /// Dedupe: same content already live -> bump it to the top. Nil when no live
    /// row has this hash (it may have been deleted between the read and the
    /// write, in which case the caller falls through to a normal insert).
    static func bumpExisting(
        _ db: GRDB.Database, contentHash: String, now: Date, isSecret: Bool
    ) throws -> ClipItem? {
        guard let existing = try ClipItem
            .filter(sql: "contentHash = ? AND deletedAt IS NULL", arguments: [contentHash])
            .fetchOne(db)
        else { return nil }
        var bumped = existing
        bumped.useCount = try Int(Self.nextItemCounter(
            after: Int64(existing.useCount), itemID: existing.id, counter: .useCount
        ))
        bumped.lastUsedAt = now
        bumped.updatedAt = now
        bumped.lamport = try Self.nextItemCounter(
            after: existing.lamport, itemID: existing.id, counter: .revision
        )
        try bumped.update(db)
        if isSecret, !existing.isSecret {
            try Self.protectSensitiveItem(db, itemID: bumped.id, label: "Sensitive content")
            bumped = try ClipItem.fetchOne(db, key: bumped.id) ?? bumped
        }
        return bumped
    }
}
