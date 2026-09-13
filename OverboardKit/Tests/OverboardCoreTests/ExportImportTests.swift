import Foundation
@testable import OverboardCore
import Testing

/// A store plus the temporary directories it owns, so each test gets a fresh
/// database, blob store, and export folder that clean themselves up.
private struct Harness {
    let store: ClipStore
    let root: URL

    init() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("overboard-archive-\(UUID().uuidString)", isDirectory: true)
        let blobs = try BlobStore(directory: self.root.appendingPathComponent("blobs", isDirectory: true))
        self.store = try ClipStore(dbWriter: OverboardDatabase.openInMemory(), blobs: blobs)
    }

    var exportDirectory: URL {
        self.root.appendingPathComponent("export", isDirectory: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: self.root)
    }
}

private func snapshot(_ reps: [(String, Data)], app: String = "TextEdit") -> PasteboardSnapshot {
    PasteboardSnapshot(
        reps: reps.map { .init(uti: $0.0, data: $0.1) },
        sourceBundleID: "com.apple.TextEdit",
        sourceAppName: app
    )
}

private func textSnapshot(_ text: String) -> PasteboardSnapshot {
    snapshot([(WellKnownUTI.plainText, Data(text.utf8))])
}

private func fileSnapshot(_ paths: [String]) throws -> PasteboardSnapshot {
    let urls = paths.map { URL(fileURLWithPath: $0).absoluteString }
    return try snapshot([
        (WellKnownUTI.fileURLs, JSONEncoder().encode(urls)),
        (WellKnownUTI.plainText, Data(paths.joined(separator: "\n").utf8)),
    ])
}

/// Deliberately larger than `Representation.inlineThreshold` so the payload
/// lands in the blob store and the archive has to copy a file.
private func largeImageSnapshot() -> PasteboardSnapshot {
    snapshot([(WellKnownUTI.png, Data(repeating: 0x7F, count: Representation.inlineThreshold + 512))])
}

struct ExportImportTests {
    /// Seeds one clip of every kind, exports, and restores into an empty store.
    @Test func roundTripsEveryKind() async throws {
        let source = try Harness()
        let destination = try Harness()
        defer {
            source.cleanUp()
            destination.cleanUp()
        }

        let text = try #require(await source.store.ingest(textSnapshot("deploy checklist")))
        let link = try #require(await source.store.ingest(textSnapshot("https://example.com/post")))
        try await source.store.attachLinkMetadata(
            itemID: link.id,
            title: "Example Post",
            description: "A worked example",
            faviconPNG: Data([0x01, 0x02]),
            previewImagePNG: Data([0x03, 0x04])
        )
        try await source.store.setPinned(id: text.id, true)
        let image = try #require(await source.store.ingest(largeImageSnapshot()))
        let file = try #require(try await source.store.ingest(fileSnapshot(["/tmp/report.pdf"])))
        let color = try #require(await source.store.ingest(
            snapshot([(WellKnownUTI.color, Data([0x33, 0x66, 0xFF]))])
        ))

        let exported = try await source.store.export(to: source.exportDirectory)
        #expect(exported.itemCount == 5)
        // Only the oversized image payload is blob-backed.
        #expect(exported.blobCount == 1)

        let summary = try await destination.store.import(from: source.exportDirectory)
        #expect(summary.imported == 5)
        #expect(summary.duplicatesSkipped == 0)
        #expect(summary.malformedLines.isEmpty)
        #expect(summary.missingBlobs == 0)

        let restored = try await destination.store.recent()
        #expect(Set(restored.map(\.kind)) == Set(ItemKind.allCases))
        #expect(Set(restored.map(\.contentHash)) == Set([text, link, image, file, color].map(\.contentHash)))

        // Link metadata survives: re-classifying the URL could never recover it.
        let restoredLink = try #require(restored.first { $0.kind == .link })
        #expect(restoredLink.linkTitle == "Example Post")
        #expect(restoredLink.linkDescription == "A worked example")
        #expect(restoredLink.faviconData == Data([0x01, 0x02]))
        #expect(restoredLink.previewImageData == Data([0x03, 0x04]))

        // The blob-backed image payload came across byte for byte.
        let restoredImage = try #require(restored.first { $0.kind == .image })
        let reps = try await destination.store.representations(for: restoredImage.id)
        let payload = try await destination.store.payload(for: #require(reps.first))
        #expect(payload.count == Representation.inlineThreshold + 512)
        #expect(reps.first?.blobHash != nil)

        // File paths decode from the restored representation.
        let restoredFile = try #require(restored.first { $0.kind == .file })
        #expect(try await destination.store.filePaths(for: restoredFile.id) == ["/tmp/report.pdf"])
    }

    /// Pins and usage counters are part of the backup — restoring a library that
    /// forgets what you pinned isn't a restore.
    @Test func preservesPinsAndUsage() async throws {
        let source = try Harness()
        let destination = try Harness()
        defer {
            source.cleanUp()
            destination.cleanUp()
        }

        let item = try #require(await source.store.ingest(textSnapshot("pinned and reused")))
        try await source.store.setPinned(id: item.id, true)
        try await source.store.markUsed(id: item.id)
        try await source.store.markUsed(id: item.id)
        let original = try #require(await source.store.recent().first)

        try await source.store.export(to: source.exportDirectory)
        _ = try await destination.store.import(from: source.exportDirectory)

        let restored = try #require(await destination.store.recent().first)
        #expect(restored.isPinned)
        #expect(restored.useCount == original.useCount)
        #expect(restored.lastUsedAt.timeIntervalSince(original.lastUsedAt).magnitude < 0.001)
    }

    @Test func secretsAreExcludedByDefaultAndIncludedOnRequest() async throws {
        let source = try Harness()
        let defaultDestination = try Harness()
        let secretDestination = try Harness()
        defer {
            source.cleanUp()
            defaultDestination.cleanUp()
            secretDestination.cleanUp()
        }

        try await source.store.ingest(textSnapshot("ordinary note"))
        let secret = try #require(await source.store.ingest(
            textSnapshot("AKIAIOSFODNN7EXAMPLE")
        ))
        try #require(secret.isSecret)

        let withoutSecrets = try await source.store.export(to: source.exportDirectory)
        #expect(withoutSecrets.itemCount == 1)
        #expect(withoutSecrets.secretsExcluded == 1)
        _ = try await defaultDestination.store.import(from: source.exportDirectory)
        #expect(try await defaultDestination.store.recent().allSatisfy { !$0.isSecret })

        let secretsDirectory = source.root.appendingPathComponent("export-secrets", isDirectory: true)
        let withSecrets = try await source.store.export(to: secretsDirectory, includeSecrets: true)
        #expect(withSecrets.itemCount == 2)
        #expect(withSecrets.secretsExcluded == 0)
        _ = try await secretDestination.store.import(from: secretsDirectory)
        #expect(try await secretDestination.store.recent().contains { $0.isSecret })
    }

    /// Re-importing the same archive is a no-op rather than a duplicate library.
    @Test func duplicatesAreSkippedAndCounted() async throws {
        let source = try Harness()
        defer { source.cleanUp() }

        try await source.store.ingest(textSnapshot("first clip"))
        try await source.store.ingest(textSnapshot("second clip"))
        try await source.store.export(to: source.exportDirectory)

        // Straight back into the store it came from: every record is live already.
        let summary = try await source.store.import(from: source.exportDirectory)
        #expect(summary.imported == 0)
        #expect(summary.duplicatesSkipped == 2)
        #expect(try await source.store.recent().count == 2)
    }

    /// The FTS index is contentless, so an import that skipped the index write
    /// would leave rows that exist but can never be found.
    @Test func importedTextIsSearchable() async throws {
        let source = try Harness()
        let destination = try Harness()
        defer {
            source.cleanUp()
            destination.cleanUp()
        }

        try await source.store.ingest(textSnapshot("quarterly revenue projection"))
        try await source.store.export(to: source.exportDirectory)
        _ = try await destination.store.import(from: source.exportDirectory)

        let hits = try await destination.store.search("revenue")
        #expect(hits.count == 1)
        #expect(hits.first?.previewText == "quarterly revenue projection")
    }

    /// One unreadable line costs one clip; the rest of the archive still restores.
    @Test func malformedLinesAreReportedNotFatal() async throws {
        let source = try Harness()
        let destination = try Harness()
        defer {
            source.cleanUp()
            destination.cleanUp()
        }

        try await source.store.ingest(textSnapshot("good clip one"))
        try await source.store.ingest(textSnapshot("good clip two"))
        try await source.store.export(to: source.exportDirectory)

        let itemsURL = source.exportDirectory.appendingPathComponent(ClipArchive.itemsFileName)
        var lines = try String(contentsOf: itemsURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        lines.insert("{ this is not json", at: 1)
        try (lines.joined(separator: "\n") + "\n").write(to: itemsURL, atomically: true, encoding: .utf8)

        let summary = try await destination.store.import(from: source.exportDirectory)
        #expect(summary.imported == 2)
        #expect(summary.malformedLines.count == 1)
        #expect(summary.malformedLines.first?.hasPrefix("line 2:") == true)
    }

    /// A blob that has already gone from disk (the same state
    /// `maintenanceSweep` reports as missing) must not abort the export — the
    /// row is still written and the archive still imports — but the summary
    /// has to say so instead of reporting an unqualified success.
    @Test func missingBlobIsCountedNotFatal() async throws {
        let source = try Harness()
        defer { source.cleanUp() }

        try await source.store.ingest(textSnapshot("kept text"))
        let image = try #require(try await source.store.ingest(largeImageSnapshot()))
        let hash = try #require(try await source.store.representations(for: image.id).compactMap(\.blobHash).first)
        let blobs = try BlobStore(directory: source.root.appendingPathComponent("blobs", isDirectory: true))
        try FileManager.default.removeItem(at: blobs.url(for: hash))

        let summary = try await source.store.export(to: source.exportDirectory)
        #expect(summary.itemCount == 2)
        #expect(summary.blobCount == 0)
        #expect(summary.blobsMissing == 1)
    }

    @Test func importingAFolderWithoutAnArchiveThrows() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let empty = harness.root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        await #expect(throws: ClipArchive.Failure.notAnArchive(empty)) {
            try await harness.store.import(from: empty)
        }
    }
}
