import Foundation
@testable import OverboardCore
import Testing

enum ArchiveCounterField: CaseIterable, Sendable {
    case revision, useCount, byteSize, charCount, lineCount, pixelWidth, pixelHeight, fileCount

    func set(_ value: Int, in record: inout ClipArchive.Record) {
        switch self {
        case .revision: record.lamport = Int64(value)
        case .useCount: record.useCount = value
        case .byteSize: record.byteSize = value
        case .charCount: record.charCount = value
        case .lineCount: record.lineCount = value
        case .pixelWidth: record.pixelWidth = value
        case .pixelHeight: record.pixelHeight = value
        case .fileCount: record.fileCount = value
        }
    }
}

struct ArchiveRevisionValidationTests {
    @Test(arguments: ArchiveCounterField.allCases, [false, true])
    func maximumItemCounterFailsBeforeMutation(field: ArchiveCounterField, legacy: Bool) async throws {
        let source = try ArchiveHarness()
        let destination = try ArchiveHarness()
        defer { source.remove(); destination.remove() }
        _ = try await source.text("incoming archive item")
        let existing = try await destination.text("existing destination item")
        try await source.store.export(to: source.archive)
        try source.rewriteFirstRecord({ field.set(Int.max, in: &$0) }, legacy: legacy)
        await #expect(throws: ClipArchive.Failure.self) { try await destination.store.import(from: source.archive) }
        #expect(try await destination.store.recent().map(\.id) == [existing.id])
    }

    @Test func maximumSnippetRevisionFailsBeforeItemsOrBlobsAreRestored() async throws {
        let source = try ArchiveHarness()
        let destination = try ArchiveHarness()
        defer { source.remove(); destination.remove() }
        _ = try await source.image()
        let snippet = try await source.store.saveSnippet(Snippet(title: "Incoming", body: "incoming"))
        let existing = try await destination.text("existing destination item")
        try await destination.store.saveSnippet(Snippet(title: "Existing", body: "unchanged"))
        let existingSnippets = try await destination.store.snippets()
        try await source.store.export(to: source.archive)
        var exhausted = snippet
        exhausted.lamport = Int64.max
        try self.rewriteSnippet(exhausted, in: source.archive)
        await #expect(throws: ClipArchive.Failure.self) { try await destination.store.import(from: source.archive) }
        #expect(try await destination.store.recent().map(\.id) == [existing.id])
        #expect(try await destination.store.snippets() == existingSnippets)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.blobs.directory.path).isEmpty)
    }

    @Test func largestImportableRevisionIsValid() throws {
        try ArchiveValidation.snippet(Snippet(title: "Boundary", body: "body", lamport: Int64.max - 1))
        let now = Date()
        let item = ClipItem(
            contentHash: String(repeating: "a", count: 64), kind: .text, previewText: nil,
            sourceBundleID: nil, sourceAppName: nil, byteSize: 1, createdAt: now, lastUsedAt: now, updatedAt: now
        )
        var record = ClipArchive.Record(item: item, searchText: nil, representations: [])
        record.lamport = Int64.max - 1
        record.useCount = Int.max - 1
        try ArchiveValidation.record(record)
        record.lamport = nil
        try ArchiveValidation.record(record)
    }

    @Test(arguments: ArchiveCounterField.allCases)
    func negativeItemCountersAreInvalid(field: ArchiveCounterField) throws {
        let now = Date()
        let item = ClipItem(
            contentHash: String(repeating: "a", count: 64), kind: .text, previewText: nil,
            sourceBundleID: nil, sourceAppName: nil, byteSize: 1, createdAt: now, lastUsedAt: now, updatedAt: now
        )
        var record = ClipArchive.Record(item: item, searchText: nil, representations: [])
        field.set(-1, in: &record)
        #expect(throws: ClipArchive.Failure.self) { try ArchiveValidation.record(record) }
    }

    @Test func maximumRepresentationSizeIsInvalid() throws {
        let rep = ClipArchive.Rep(uti: WellKnownUTI.plainText, data: Data(), byteSize: Int.max)
        #expect(throws: ClipArchive.Failure.self) {
            try ArchiveValidation.representation(rep, limits: .init(), manifest: nil)
        }
    }

    @Test(arguments: [
        ClipArchive.SettingValue.integer(Int.max), .counts(["snippet": Int.max]), .counts(["snippet": -1]),
    ])
    func unsupportedSettingsCountersAreInvalid(value: ClipArchive.SettingValue) throws {
        let settings = ClipArchive.Settings(namespace: "test", version: 1, values: ["counter": value])
        #expect(throws: ClipArchive.Failure.self) { try ArchiveValidation.settings(settings) }
    }

    @Test func largestSupportedSettingsCounterIsValid() throws {
        let settings = ClipArchive.Settings(
            namespace: "test", version: 1, values: ["counter": .counts(["snippet": Int.max - 1])]
        )
        try ArchiveValidation.settings(settings)
    }

    private func rewriteSnippet(_ snippet: Snippet, in archive: URL) throws {
        let data = try ClipJSONCoding.archiveEncoder().encode(snippet) + Data([0x0A])
        try data.write(to: archive.appendingPathComponent(ClipArchive.snippetsFileName))
        let manifestURL = archive.appendingPathComponent(ClipArchive.manifestFileName)
        var manifest = try ClipJSONCoding.archiveDecoder().decode(
            ClipArchive.Manifest.self, from: Data(contentsOf: manifestURL)
        )
        manifest.snippetsChecksum = BlobStore.hash(data)
        try ClipJSONCoding.archiveEncoder().encode(manifest).write(to: manifestURL)
    }
}
