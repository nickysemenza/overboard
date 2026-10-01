import Foundation
import GRDB
@testable import OverboardCore
import Testing

struct SecureArchiveTests {
    @Test func wholeLibraryIncludesPinsSnippetsTypedSettingsAndLamport() async throws {
        let source = try ArchiveHarness()
        let destination = try ArchiveHarness()
        defer { source.remove(); destination.remove() }
        let item = try await source.text("archive fixture")
        try await source.store.setPinned(id: item.id, true)
        try await source.store.saveSnippet(.init(id: "fixture-snippet", title: "Greeting", body: "Hello {clipboard}"))
        let settings = ClipArchive.Settings(namespace: "test", version: 1, values: [
            "pref": .boolean(true), "quicklink": .string("docs = https://example.test"),
            "alias": .string("edit = Editor"), "ranking": .counts(["item": 3]),
        ], hotkeys: ["launcher": .init(keyCode: 49, modifiers: 2048)])
        let exported = try await source.store.export(to: source.archive, settings: settings)
        #expect(exported.snippetCount == 1)
        #expect(exported.includesSettings)
        let imported = try await destination.store.import(from: source.archive)
        #expect(imported.settings == settings)
        #expect(imported.snippetsImported == 1)
        let restored = try #require(try await destination.store.recent().first(where: { $0.id == item.id }))
        #expect(restored.isPinned)
        #expect(restored.lamport == 1)
        #expect(try await destination.store.snippets().count == 1)
        let repeated = try await destination.store.import(from: source.archive)
        #expect(repeated.imported == 0)
        #expect(repeated.snippetsImported == 0)
    }

    @Test(arguments: ["../outside", "/tmp/outside", "aa/../../outside", String(repeating: "A", count: 64)])
    func traversalAndNoncanonicalHashesFailBeforeMutation(hash: String) async throws {
        let source = try ArchiveHarness()
        let destination = try ArchiveHarness()
        defer { source.remove(); destination.remove() }
        _ = try await source.image()
        try await source.store.export(to: source.archive)
        try source.rewriteFirstRecord({ $0.representations[0].blob = hash }, legacy: true)
        await #expect(throws: ClipArchive.Failure.self) { try await destination.store.import(from: source.archive) }
        #expect(try await destination.store.recent().isEmpty)
    }

    @Test(arguments: ["root", "items", "blob-directory", "blob-file"])
    func symlinksAreRejected(location: String) async throws {
        let source = try ArchiveHarness()
        let destination = try ArchiveHarness()
        defer { source.remove(); destination.remove() }
        let fixture = try await source.image()
        try await source.store.export(to: source.archive)
        var importURL = source.archive
        let target: URL
        switch location {
        case "root":
            importURL = source.root.appendingPathComponent("link")
            target = source.archive
        case "items": target = source.archive.appendingPathComponent(ClipArchive.itemsFileName)
        case "blob-directory": target = source.archive.appendingPathComponent("blobs")
        default: target = source.archive.appendingPathComponent("blobs/\(fixture.hash)")
        }
        if location == "root" {
            try FileManager.default.createSymbolicLink(at: importURL, withDestinationURL: target)
        } else {
            let moved = source.root.appendingPathComponent("outside")
            try FileManager.default.moveItem(at: target, to: moved)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: moved)
        }
        await #expect(throws: ClipArchive.Failure.self) { try await destination.store.import(from: importURL) }
        #expect(try await destination.store.recent().isEmpty)
    }

    @Test func wrongBlobChecksumRollsBackAllRecords() async throws {
        let source = try ArchiveHarness()
        let destination = try ArchiveHarness()
        defer { source.remove(); destination.remove() }
        let fixture = try await source.image()
        try await source.text("would otherwise import first")
        try await source.store.export(to: source.archive)
        try Data(repeating: 0x43, count: fixture.bytes.count)
            .write(to: source.archive.appendingPathComponent("blobs/\(fixture.hash)"))
        await #expect(throws: ClipArchive.Failure.checksum(fixture.hash)) {
            try await destination.store.import(from: source.archive)
        }
        #expect(try await destination.store.recent().isEmpty)
    }

    @Test func manifestChecksumRejectsTamperedInlinePayload() async throws {
        let source = try ArchiveHarness()
        let destination = try ArchiveHarness()
        defer { source.remove(); destination.remove() }
        try await source.text("original")
        try await source.store.export(to: source.archive)
        let url = source.archive.appendingPathComponent(ClipArchive.itemsFileName)
        let changed = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(
            of: "original",
            with: "modified"
        )
        try Data(changed.utf8).write(to: url)
        await #expect(throws: ClipArchive.Failure.self) { try await destination.store.import(from: source.archive) }
        #expect(try await destination.store.recent().isEmpty)
    }
}

extension SecureArchiveTests {
    @Test func partialImportRetainsReferencesAndRepeatedImportRepairsBytes() async throws {
        let source = try ArchiveHarness()
        let destination = try ArchiveHarness()
        defer { source.remove(); destination.remove() }
        let fixture = try await source.image()
        try await source.store.export(to: source.archive)
        let blobURL = source.archive.appendingPathComponent("blobs/\(fixture.hash)")
        try FileManager.default.removeItem(at: blobURL)
        let partial = try await destination.store.import(from: source.archive)
        #expect(partial.imported == 1)
        #expect(partial.missingBlobs == 1)
        #expect(try await destination.store.representations(for: fixture.item.id).first?.blobHash == fixture.hash)
        try fixture.bytes.write(to: blobURL)
        let repaired = try await destination.store.import(from: source.archive)
        #expect(repaired.imported == 0)
        #expect(repaired.duplicatesSkipped == 1)
        #expect(repaired.representationsRepaired == 1)
        #expect(try destination.blobs.data(for: fixture.hash) == fixture.bytes)
        #expect(try await destination.store.import(from: source.archive).representationsRepaired == 0)
        try Data([0x00]).write(to: destination.blobs.url(for: fixture.hash))
        #expect(try await destination.store.import(from: source.archive).representationsRepaired == 1)
        #expect(try destination.blobs.data(for: fixture.hash) == fixture.bytes)
    }

    @Test func oldPartialImportsCanRepairDroppedRepresentations() async throws {
        let source = try ArchiveHarness()
        let destination = try ArchiveHarness()
        defer { source.remove(); destination.remove() }
        let fixture = try await source.image()
        try await source.store.export(to: source.archive)
        _ = try await destination.store.import(from: source.archive)
        try await destination.database.write { db in try db.execute(
            sql: "DELETE FROM representation WHERE itemID = ?",
            arguments: [fixture.item.id]
        ) }
        let result = try await destination.store.import(from: source.archive)
        #expect(result.representationsRepaired == 1)
        #expect(try await destination.store.representations(for: fixture.item.id).count == 1)
    }

    @Test func publicationFailureKeepsPreviousBackupByteForByte() async throws {
        let source = try ArchiveHarness()
        let restored = try ArchiveHarness()
        defer { source.remove(); restored.remove() }
        try await source.text("prior good archive")
        try await source.store.export(to: source.archive)
        let prior = try Data(contentsOf: source.archive.appendingPathComponent(ClipArchive.itemsFileName))
        try await source.text("new data not published")
        await #expect(throws: ClipArchive.Failure.invalid("injected publication failure")) {
            try await source.store.exportArchive(
                to: source.archive,
                includeSecrets: false,
                settings: nil,
                limits: .init()
            ) { _, _ in
                throw ClipArchive.Failure.invalid("injected publication failure")
            }
        }
        #expect(try Data(contentsOf: source.archive.appendingPathComponent(ClipArchive.itemsFileName)) == prior)
        #expect(try await restored.store.import(from: source.archive).imported == 1)
        try await source.store.export(to: source.archive)
        #expect(try await restored.store.import(from: source.archive).imported == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: source.root.path)
            .allSatisfy { !$0.hasPrefix(".overboard-archive-") })
    }

    @Test func validationCallbackAndResourceLimitsPrecedeDatabaseMutation() async throws {
        let source = try ArchiveHarness()
        let destination = try ArchiveHarness()
        defer { source.remove(); destination.remove() }
        try await source.text("record one")
        try await source.text("record two")
        try await source.store.saveSnippet(.init(title: "Third record", body: "snippet record"))
        try await source.store.export(
            to: source.archive,
            settings: .init(namespace: "future", version: 999, values: [:])
        )
        await #expect(throws: ClipArchive.Failure.invalid("unrecognized settings")) {
            try await destination.store
                .import(from: source.archive) { _ in throw ClipArchive.Failure.invalid("unrecognized settings") }
        }
        await #expect(throws: ClipArchive.Failure.self) { try await destination.store.import(
            from: source.archive,
            limits: .init(records: 1)
        ) }
        await #expect(throws: ClipArchive.Failure.self) { try await destination.store.import(
            from: source.archive,
            limits: .init(records: 2)
        ) }
        await #expect(throws: ClipArchive.Failure.self) { try await destination.store.import(
            from: source.archive,
            limits: .init(lineBytes: 32)
        ) }
        await #expect(throws: ClipArchive.Failure.self) { try await destination.store.import(
            from: source.archive,
            limits: .init(archiveBytes: 32)
        ) }
        #expect(try await destination.store.recent().isEmpty)
    }
}

extension SecureArchiveTests {
    @Test func secretSnippetsAndConfigurationRequireExplicitOptIn() async throws {
        let source = try ArchiveHarness()
        let destination = try ArchiveHarness()
        defer { source.remove(); destination.remove() }
        let credential = "https://example.test/?access_token=archive-fixture"
        try await source.store.saveSnippet(.init(title: "Sensitive", body: credential))
        let settings = ClipArchive.Settings(namespace: "test", version: 1, values: ["quicklinks": .string(credential)])
        let defaultExport = try await source.store.export(to: source.archive, settings: settings)
        #expect(defaultExport.secretsExcluded == 2)
        #expect(defaultExport.snippetCount == 0)
        #expect(try await destination.store.import(from: source.archive).settings?.values.isEmpty == true)
        let optIn = try await source.store.export(to: source.archive, includeSecrets: true, settings: settings)
        #expect(optIn.secretsExcluded == 0)
        #expect(try await destination.store.import(from: source.archive).snippetsImported == 1)
    }

    @Test func unlistedBlobReferenceRejectsTheEntireImport() async throws {
        let source = try ArchiveHarness()
        let destination = try ArchiveHarness()
        defer { source.remove(); destination.remove() }
        _ = try await source.image()
        try await source.store.export(to: source.archive)
        let manifestURL = source.archive.appendingPathComponent(ClipArchive.manifestFileName)
        var manifest = try ClipJSONCoding.archiveDecoder().decode(
            ClipArchive.Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        manifest.blobs = [:]
        try ClipJSONCoding.archiveEncoder().encode(manifest).write(to: manifestURL)
        await #expect(throws: ClipArchive.Failure.self) { try await destination.store.import(from: source.archive) }
        #expect(try await destination.store.recent().isEmpty)
    }

    @Test func legacyRecordWithoutRevisionStillRestoresAllPayloads() async throws {
        let source = try ArchiveHarness()
        let destination = try ArchiveHarness()
        defer { source.remove(); destination.remove() }
        let original = try await source.text("legacy searchable fixture")
        try await source.store.export(to: source.archive)
        try source.rewriteFirstRecord({ $0.lamport = nil }, legacy: true)
        let imported = try await destination.store.import(from: source.archive)
        #expect(imported.imported == 1)
        #expect(imported.settings == nil)
        let restored = try #require(try await destination.store.materialize(itemIDs: [original.id]).first)
        #expect(restored.item.lamport == 0)
        #expect(restored.representations.first?.payload == Data("legacy searchable fixture".utf8))
    }

    @Test func collidingSnippetsAreRecoveredWithoutOverwritingEitherBody() async throws {
        let source = try ArchiveHarness()
        let destination = try ArchiveHarness()
        defer { source.remove(); destination.remove() }
        try await source.store.saveSnippet(.init(id: "collision", title: "Source", body: "archived body"))
        try await destination.store.saveSnippet(.init(id: "collision", title: "Destination", body: "existing body"))
        try await source.store.export(to: source.archive)
        #expect(try await destination.store.import(from: source.archive).snippetsImported == 1)
        #expect(try await destination.store.import(from: source.archive).snippetsImported == 0)
        let snippets = try await destination.store.snippets()
        #expect(Set(snippets.map(\.body)) == ["archived body", "existing body"])
        #expect(snippets.first(where: { $0.id == "collision" })?.body == "existing body")
    }

    @Test func publicationRejectsSymlinkDestinationAndKeepsItsTarget() async throws {
        let source = try ArchiveHarness()
        defer { source.remove() }
        try await source.text("unchanged backup")
        try await source.store.export(to: source.archive)
        let prior = try Data(contentsOf: source.archive.appendingPathComponent(ClipArchive.itemsFileName))
        let link = source.root.appendingPathComponent("linked-archive")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source.archive)
        await #expect(throws: ClipArchive.Failure.self) { try await source.store.export(to: link) }
        #expect(try Data(contentsOf: source.archive.appendingPathComponent(ClipArchive.itemsFileName)) == prior)
    }

    @Test func blobAndRepresentationLimitsRejectBeforeDatabaseMutation() async throws {
        let source = try ArchiveHarness()
        let destination = try ArchiveHarness()
        defer { source.remove(); destination.remove() }
        _ = try await source.image()
        try await source.text("second representation")
        try await source.store.export(to: source.archive)
        await #expect(throws: ClipArchive.Failure.self) { try await destination.store.import(
            from: source.archive,
            limits: .init(blobBytes: 16)
        ) }
        await #expect(throws: ClipArchive.Failure.self) { try await destination.store.import(
            from: source.archive,
            limits: .init(representations: 1)
        ) }
        #expect(try await destination.store.recent().isEmpty)
    }

    @Test func pasteboardItemIndicesRoundTripWithoutCollapsingIdenticalFlavors() async throws {
        let source = try ArchiveHarness()
        let destination = try ArchiveHarness()
        defer { source.remove(); destination.remove() }
        let bytes = Data("shared item text".utf8)
        let item = try #require(await source.store.ingest(.init(reps: [
            .init(uti: WellKnownUTI.plainText, data: bytes, itemIndex: 0),
            .init(uti: WellKnownUTI.html, data: Data("<b>shared item text</b>".utf8), itemIndex: 0),
            .init(uti: WellKnownUTI.plainText, data: bytes, itemIndex: 1),
        ], sourceBundleID: nil, sourceAppName: nil)))
        try await source.store.export(to: source.archive)
        #expect(try await destination.store.import(from: source.archive).imported == 1)
        let restored = try #require(try await destination.store.materialize(itemIDs: [item.id]).first)
        #expect(restored.representations.map(\.representation.itemIndex) == [0, 0, 1])
        #expect(restored.representations.map(\.payload) == [bytes, Data("<b>shared item text</b>".utf8), bytes])
        #expect(try await destination.store.import(from: source.archive).representationsRepaired == 0)
    }

    @Test func rawSecretBeyondSearchLimitIsProtectedEvenWhenLegacyFlagsAreWrong() async throws {
        let source = try ArchiveHarness()
        let destination = try ArchiveHarness()
        defer { source.remove(); destination.remove() }
        let body = String(repeating: "ordinary text ", count: 4000) + "AKIAIOSFODNN7EXAMPLE"
        let original = try await source.text(body)
        try await source.database.write { db in
            try db.execute(sql: "UPDATE item SET isSecret = 0 WHERE id = ?", arguments: [original.id])
        }
        #expect(try await source.store.export(to: source.archive).secretsExcluded == 1)
        try await source.store.export(to: source.archive, includeSecrets: true)
        try source.rewriteFirstRecord { record in
            record.secret = false
            record.searchText = "ordinary"
            record.preview = "legacy unmasked preview"
            record.sourceURL = "https://example.test/source"
            record.sourceTitle = "source title"
            record.aiTitle = "legacy title"
            record.aiSummary = "legacy summary"
        }
        #expect(try await destination.store.import(from: source.archive).imported == 1)
        let restored = try #require(try await destination.store.materialize(itemIDs: [original.id]).first)
        #expect(restored.item.isSecret)
        #expect(restored.item.previewText == "Secret — AWS access key")
        #expect(restored.item.sourceURL == nil)
        #expect(restored.item.sourceTitle == nil)
        #expect(restored.item.aiTitle == nil)
        #expect(restored.item.aiSummary == nil)
        #expect(restored.representations.first?.payload == Data(body.utf8))
        #expect(try await destination.store.search("ordinary").isEmpty)
        #expect(try await destination.store.search("AKIA").isEmpty)
    }
}
