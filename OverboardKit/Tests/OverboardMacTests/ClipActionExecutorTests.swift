import AppKit
@testable import OverboardCore
@testable import OverboardMac
import Testing

/// Covers the half of an action that `ClipActionTests` can't: the effects.
/// Downloads is injected, so `saveImageToDownloads` writes into a temp
/// directory rather than the developer's real ~/Downloads, and the HUD and
/// paste stack are closures we can read back.
@MainActor
struct ClipActionExecutorTests {
    /// Collects the HUD messages and stack pushes an executor produced.
    private final class Recorder {
        var flashes: [String] = []
        var stacked: [[ClipItem]] = []
    }

    private func makeStore() throws -> ClipStore {
        let queue = try OverboardDatabase.openInMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-actions-\(UUID().uuidString)", isDirectory: true)
        return try ClipStore(dbWriter: queue, blobs: BlobStore(directory: dir))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeExecutor(
        store: ClipStore,
        recorder: Recorder,
        downloads: URL?
    ) -> ClipActionExecutor {
        ClipActionExecutor(
            store: store,
            pasteback: PastebackService(store: store),
            flash: { recorder.flashes.append($0) },
            addToStack: { recorder.stacked.append($0) },
            downloadsDirectory: { downloads }
        )
    }

    /// A small solid-color PNG — a real image payload for ingest to store.
    private func pngData() throws -> Data {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemTeal.drawSwatch(in: NSRect(x: 0, y: 0, width: 8, height: 8))
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private func textSnapshot(_ text: String) -> PasteboardSnapshot {
        PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.plainText, data: Data(text.utf8))],
            sourceBundleID: "com.test",
            sourceAppName: "Test"
        )
    }

    // MARK: - Save to Downloads

    @Test func savesAnImageIntoTheInjectedDirectory() async throws {
        let store = try self.makeStore()
        let recorder = Recorder()
        let downloads = try self.temporaryDirectory()
        let png = try self.pngData()
        let item = try #require(try await store.ingest(PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.png, data: png)],
            sourceBundleID: "com.test",
            sourceAppName: "Test"
        )))

        let executor = self.makeExecutor(store: store, recorder: recorder, downloads: downloads)
        let written = try #require(await executor.saveImageToDownloads(itemID: item.id))

        #expect(written.pathExtension == "png")
        #expect(written.lastPathComponent.hasPrefix("Overboard "))
        #expect(FileManager.default.fileExists(atPath: written.path))
        #expect(try Data(contentsOf: written) == png)
        #expect(recorder.flashes == ["Saved to Downloads"])
    }

    @Test func reportsAnItemWithNoImagePayload() async throws {
        let store = try self.makeStore()
        let recorder = Recorder()
        let downloads = try self.temporaryDirectory()
        let item = try #require(try await store.ingest(self.textSnapshot("just text")))

        let executor = self.makeExecutor(store: store, recorder: recorder, downloads: downloads)
        #expect(await executor.saveImageToDownloads(itemID: item.id) == nil)
        #expect(recorder.flashes == ["Couldn't save image"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: downloads.path).isEmpty)
    }

    @Test func reportsAMissingDownloadsDirectory() async throws {
        let store = try self.makeStore()
        let recorder = Recorder()
        let png = try self.pngData()
        let item = try #require(try await store.ingest(PasteboardSnapshot(
            reps: [.init(uti: WellKnownUTI.png, data: png)],
            sourceBundleID: "com.test",
            sourceAppName: "Test"
        )))

        let executor = self.makeExecutor(store: store, recorder: recorder, downloads: nil)
        #expect(await executor.saveImageToDownloads(itemID: item.id) == nil)
        #expect(recorder.flashes == ["Couldn't save image"])
    }

    // MARK: - Effects that stay inside the app

    @Test func addToStackPushesAndCountsInTheHUD() async throws {
        let store = try self.makeStore()
        let recorder = Recorder()
        let first = try #require(try await store.ingest(self.textSnapshot("one")))
        let second = try #require(try await store.ingest(self.textSnapshot("two")))

        let executor = self.makeExecutor(store: store, recorder: recorder, downloads: nil)
        await executor.execute(.addToStack([first, second]), target: nil)

        #expect(recorder.stacked.map { $0.map(\.id) } == [[first.id, second.id]])
        #expect(recorder.flashes == ["2 items on the stack — ⌥⌘V to paste"])
    }

    @Test func showMessageGoesStraightToTheHUD() async throws {
        let store = try self.makeStore()
        let recorder = Recorder()
        let executor = self.makeExecutor(store: store, recorder: recorder, downloads: nil)

        await executor.execute(.showMessage("Not valid JSON"), target: nil)
        #expect(recorder.flashes == ["Not valid JSON"])
    }

    /// End to end through the pure half: `run` prefetches the payload, lets
    /// `ClipAction` decide, then carries the effect out.
    @Test func runPrefetchesPayloadsForThePureAction() async throws {
        let store = try self.makeStore()
        let recorder = Recorder()
        let item = try #require(try await store.ingest(self.textSnapshot("one two three")))

        let executor = self.makeExecutor(store: store, recorder: recorder, downloads: nil)
        await executor.run(.wordCount, on: [item], target: nil)

        #expect(recorder.flashes == ["3 words · 13 characters"])
    }

    @Test func runReportsWhenTheActionCannotApply() async throws {
        let store = try self.makeStore()
        let recorder = Recorder()
        let item = try #require(try await store.ingest(self.textSnapshot("not json at all")))

        let executor = self.makeExecutor(store: store, recorder: recorder, downloads: nil)
        await executor.run(.prettyPrintJSON, on: [item], target: nil)

        #expect(recorder.flashes == ["Not valid JSON"])
    }
}
