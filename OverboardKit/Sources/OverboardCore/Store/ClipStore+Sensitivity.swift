import Foundation
import GRDB

extension ClipStore {
    public func isEnrichmentEligible(itemID: String) async throws -> Bool {
        try await self.dbWriter.read { db in
            try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM item WHERE id = ? AND isSecret = 0 AND deletedAt IS NULL)",
                arguments: [itemID]
            ) ?? false
        }
    }

    static func protectSensitiveItem(_ db: GRDB.Database, itemID: String, label: String) throws {
        try checkItemCountersCanAdvance(db, itemID: itemID)
        try removeFromFTS(db, itemID: itemID)
        try db.execute(sql: "DELETE FROM item_embedding WHERE itemID = ?", arguments: [itemID])
        try db.execute(
            sql: """
            UPDATE item SET isSecret = 1, previewText = ?, searchText = NULL,
                sourceURL = NULL, sourceTitle = NULL, aiTitle = NULL, category = NULL,
                aiSummary = NULL, linkTitle = NULL, linkDescription = NULL,
                faviconData = NULL, previewImageData = NULL, charCount = NULL,
                lineCount = NULL, pixelWidth = NULL, pixelHeight = NULL, fileCount = NULL,
                updatedAt = ?, lamport = lamport + 1
            WHERE id = ? AND deletedAt IS NULL
            """,
            arguments: [ClipSensitivity.maskedPreview(label: label), Date(), itemID]
        )
    }
}
