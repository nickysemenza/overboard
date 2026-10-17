import Foundation
import GRDB

/// What a completed full scan of one root vouches for: every filesystem change
/// up to `eventID` (on the volume identified by `deviceUUID`, under the scan
/// configuration `configHash`) is reflected in the index. FSEvents can replay
/// from that ID instead of re-enumerating the root.
public struct FileIndexScanState: Sendable, Equatable {
    public var root: String
    public var deviceUUID: String
    public var eventID: UInt64
    public var configHash: String
    public var completedAt: Date

    public init(root: String, deviceUUID: String, eventID: UInt64, configHash: String, completedAt: Date = Date()) {
        self.root = root.precomposedStringWithCanonicalMapping
        self.deviceUUID = deviceUUID
        self.eventID = eventID
        self.configHash = configHash
        self.completedAt = completedAt
    }
}

/// Lives in the same rebuildable file as the entries it describes, so the two
/// can never disagree about whether a root has been scanned.
public extension FileNameIndex {
    func scanStates() async throws -> [FileIndexScanState] {
        try await self.database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM scan_state").map { row in
                let event: Int64 = row["eventID"]
                return FileIndexScanState(
                    root: row["root"], deviceUUID: row["deviceUUID"], eventID: UInt64(max(0, event)),
                    configHash: row["configHash"], completedAt: row["completedAt"]
                )
            }
        }
    }

    func saveScanState(_ state: FileIndexScanState) async throws {
        try Task.checkCancellation()
        try await self.database.write { db in
            try db.execute(sql: """
            INSERT OR REPLACE INTO scan_state (root, deviceUUID, eventID, configHash, completedAt)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [
                state.root, state.deviceUUID, Int64(clamping: state.eventID), state.configHash, state.completedAt,
            ])
        }
    }

    /// Invalidates a root before its rescan starts, so a crash mid-scan can
    /// never leave a stale ID vouching for a half-reconciled index.
    func clearScanState(root: String) async throws {
        try await self.database.write { db in
            try db.execute(sql: "DELETE FROM scan_state WHERE root = ?",
                           arguments: [root.precomposedStringWithCanonicalMapping])
        }
    }

    /// Moves every saved ID forward, never back, and only for the configuration
    /// that was running: a different one has already invalidated its rows.
    func advanceScanStates(to eventID: UInt64, configHash: String, at date: Date = Date()) async throws {
        let value = Int64(clamping: eventID)
        try await self.database.write { db in
            try db.execute(sql: """
            UPDATE scan_state SET eventID = ?, completedAt = ? WHERE eventID < ? AND configHash = ?
            """, arguments: [value, date, value, configHash])
        }
    }
}
