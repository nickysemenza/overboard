import Foundation
import GRDB
@testable import OverboardCore
import Testing

struct FileNameIndexScanStateTests {
    private func state(_ root: String, event: UInt64 = 100) -> FileIndexScanState {
        FileIndexScanState(
            root: root, deviceUUID: "DEVICE", eventID: event, configHash: "config",
            completedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func databaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("files.sqlite")
    }

    @Test func scanStateRoundTripsAndSurvivesReopening() async throws {
        let url = try self.databaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try FileNameIndex(url: url)
        let saved = self.state("/fixture/a")
        try await first.saveScanState(saved)
        try await first.saveScanState(self.state("/fixture/b", event: 7))
        let reopened = try await FileNameIndex(url: url).scanStates().sorted { $0.root < $1.root }
        #expect(reopened == [saved, self.state("/fixture/b", event: 7)])
    }

    @Test func advanceMovesForwardOnlyForTheRunningConfiguration() async throws {
        let index = try FileNameIndex()
        try await index.saveScanState(self.state("/fixture/a", event: 100))
        try await index.advanceScanStates(to: 50, configHash: "config")
        #expect(try await index.scanStates().first?.eventID == 100)
        try await index.advanceScanStates(to: 200, configHash: "other")
        #expect(try await index.scanStates().first?.eventID == 100)
        try await index.advanceScanStates(to: 200, configHash: "config")
        #expect(try await index.scanStates().first?.eventID == 200)
    }

    @Test func resetRetainRootsAndClearDropTheStateThatVouchedForEntries() async throws {
        let index = try FileNameIndex()
        for root in ["/fixture/a", "/fixture/b", "/fixture/c"] {
            try await index.saveScanState(self.state(root))
        }
        try await index.clearScanState(root: "/fixture/c")
        try await index.retainRoots(["/fixture/a"])
        #expect(try await index.scanStates().map(\.root) == ["/fixture/a"])
        try await index.reset()
        #expect(try await index.scanStates().isEmpty)
    }

    @Test func setLastOpenedWritesOnlyRowsThatChanged() async throws {
        let url = try self.databaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let index = try FileNameIndex(url: url)
        try await index.upsert(["a", "b", "c"].map {
            IndexedFile(path: "/fixture/\($0).txt", name: "\($0).txt", root: "/fixture", generation: "g")
        })
        let now = Date(timeIntervalSince1970: 1_700_000_000.1234)
        try await index.setLastOpened(["/fixture/a.txt": now, "/fixture/b.txt": now, "/fixture/gone.txt": now])
        // A persistent trigger (unlike a temp one) fires for the index's own
        // connection, recording every row an UPDATE touches.
        let audit = try DatabaseQueue(path: url.path)
        try await audit.write { db in
            try db.execute(sql: """
            CREATE TABLE touched (path TEXT);
            CREATE TRIGGER track AFTER UPDATE OF lastOpenedAt ON file_entry
            BEGIN INSERT INTO touched VALUES (new.path); END;
            """)
        }
        // b is unchanged, a moves, c gains a date: b must not be rewritten.
        let later = now.addingTimeInterval(60)
        try await index.setLastOpened(["/fixture/a.txt": later, "/fixture/b.txt": now, "/fixture/c.txt": later])
        let touched = try await audit.read { db in try String.fetchAll(db, sql: "SELECT path FROM touched") }
        #expect(Set(touched) == ["/fixture/a.txt", "/fixture/c.txt"])
        // Dropping a path from Spotlight's answer clears exactly that date.
        try await index.setLastOpened(["/fixture/a.txt": later])
        let cleared = try await audit.read { db in
            try String.fetchAll(db, sql: "SELECT path FROM file_entry WHERE lastOpenedAt IS NULL ORDER BY path")
        }
        #expect(cleared == ["/fixture/b.txt", "/fixture/c.txt"])
    }
}
