import Foundation
import GRDB
@testable import OverboardCore
import Testing

struct ArchiveTimestampTests {
    @Test func millisecondEncodingIsStableAcrossRepeatedRoundTrips() throws {
        let encoder = ClipJSONCoding.archiveEncoder()
        let decoder = ClipJSONCoding.archiveDecoder()
        for second in [
            "1969-12-31T23:59:59", "1970-01-01T00:00:00",
            "2001-01-01T00:00:00", "2026-10-01T21:52:00",
        ] {
            for millisecond in 0 ..< 1000 {
                let timestamp = second + String(format: ".%03dZ", millisecond)
                let expected = Data("\"\(timestamp)\"".utf8)
                var encoded = expected
                for _ in 0 ..< 3 {
                    let date = try decoder.decode(Date.self, from: encoded)
                    encoded = try encoder.encode(date)
                    guard encoded == expected else {
                        let actual = try #require(String(data: encoded, encoding: .utf8))
                        Issue.record("Timestamp \(timestamp) changed to \(actual)")
                        return
                    }
                }
            }
        }
    }

    @Test(arguments: [
        "1969-12-31 23:59:59.005", "1970-01-01 00:00:00.010",
        "2001-01-01 00:00:00.005", "2026-10-01 21:52:00.005",
        "2026-10-01 21:52:00.010", "2026-10-01 23:59:59.999",
    ])
    func archivePreservesStoredTimestampsExactly(timestamp: String) async throws {
        let source = try ArchiveHarness()
        let destination = try ArchiveHarness()
        defer { source.remove(); destination.remove() }
        let item = try await source.text("timestamp preservation")
        try await source.database.write { database in
            try database.execute(
                sql: "UPDATE item SET createdAt = ?, lastUsedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [timestamp, timestamp, timestamp, item.id]
            )
        }
        let original = try #require(await source.store.recent().first)
        try await source.store.export(to: source.archive)
        _ = try await destination.store.import(from: source.archive)
        let restored = try #require(await destination.store.recent().first)
        #expect(restored.id == original.id)
        #expect(restored.createdAt == original.createdAt)
        #expect(restored.lastUsedAt == original.lastUsedAt)
        #expect(restored.updatedAt == original.updatedAt)
    }
}
