import Foundation
@testable import OverboardCore
import Testing

struct SearchPerformanceTests {
    private static let words = [
        "anchor", "ballast", "compass", "drift", "ensign", "fathom", "galley",
        "harbor", "inlet", "jetty", "keel", "lagoon", "mooring", "nautical",
        "oceanic", "porthole", "quay", "rudder", "starboard", "tide", "upwind",
        "vessel", "windward", "yacht", "zephyr", "deploy", "release", "branch",
        "commit", "merge", "token", "endpoint", "swift", "actor", "panel",
    ]

    private func seededStore(count: Int) async throws -> ClipStore {
        let queue = try OverboardDatabase.openInMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-perf-\(UUID().uuidString)", isDirectory: true)
        let store = try ClipStore(dbWriter: queue, blobs: BlobStore(directory: dir))

        var generator = SystemRandomNumberGenerator()
        for i in 0 ..< count {
            let wordCount = Int.random(in: 3 ... 25, using: &generator)
            let text = (0 ..< wordCount)
                .map { _ in Self.words.randomElement(using: &generator)! }
                .joined(separator: " ") + " #\(i)"
            let snapshot = PasteboardSnapshot(
                reps: [.init(uti: WellKnownUTI.plainText, data: Data(text.utf8))],
                sourceBundleID: "com.test.seeder",
                sourceAppName: "Seeder"
            )
            try await store.ingest(snapshot)
        }
        return store
    }

    @Test func searchStaysFastAtThousandItems() async throws {
        let store = try await seededStore(count: 1000)

        let queries = ["anchor", "compass dri", "sta", "vessel wind", "#42"]
        var worst: Double = 0
        for query in queries {
            let start = ContinuousClock.now
            _ = try await store.search(query, limit: 100)
            let elapsed = ContinuousClock.now - start
            let ms = Double(elapsed.components.attoseconds) / 1e15
                + Double(elapsed.components.seconds) * 1000
            worst = max(worst, ms)
        }
        // Keystroke-to-results budget is ~30ms in the UI; leave headroom for
        // slower CI machines but catch order-of-magnitude regressions.
        #expect(worst < 50, "slowest search took \(worst)ms")
    }

    @Test func recentStaysFastAtThousandItems() async throws {
        let store = try await seededStore(count: 1000)
        let start = ContinuousClock.now
        let items = try await store.recent(limit: 100)
        let elapsed = ContinuousClock.now - start
        let ms = Double(elapsed.components.attoseconds) / 1e15
            + Double(elapsed.components.seconds) * 1000
        #expect(items.count == 100)
        #expect(ms < 50, "recent() took \(ms)ms")
    }
}
