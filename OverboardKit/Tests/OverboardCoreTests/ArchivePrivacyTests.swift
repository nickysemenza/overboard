import Foundation
@testable import OverboardCore
import Testing

struct ArchivePrivacyTests {
    @Test(arguments: ["AKIAIOSFODNN7EXAMPLE", "sk-proj-abc123def456ghi789jkl012"])
    func sensitiveSelectionUsageQueryIsDetectedIndependentlyOfItemID(query: String) {
        let itemID = "app:com.example.archive-fixture"
        let key = query + "\u{1F}" + itemID
        let value = ClipArchive.SettingValue.counts([key: 7])

        #expect(ClipSensitivity.label(for: query) != nil)
        #expect(ClipSensitivity.label(for: key) == nil)
        #expect(ArchiveSensitivity.containsSecret(value))
    }

    @Test func safeRankingValuesRemainNonSensitive() {
        let safeKey = "ordinary search" + "\u{1F}" + "app:com.example.archive-fixture"
        #expect(!ArchiveSensitivity.containsSecret(.counts([safeKey: 7])))
        #expect(!ArchiveSensitivity.containsSecret(.counts(["app:com.example.archive-fixture": 3])))
        #expect(!ArchiveSensitivity.containsSecret(.timestamps(["app:com.example.archive-fixture": 1234])))
    }

    @Test func mixedSelectionUsageFiltersSensitiveQueriesWithoutMutatingInputOrSafeRanking() {
        let itemID = "app:com.example.archive-fixture"
        let safeKey = "ordinary search" + "\u{1F}" + itemID
        let sensitiveKey = "AKIAIOSFODNN7EXAMPLE" + "\u{1F}" + itemID
        let original = ClipArchive.Settings(namespace: "archive-privacy-fixture", version: 1, values: [
            "launcherSelectionUsage": .counts([safeKey: 4, sensitiveKey: 7]),
            "launcherItemUseCounts": .counts([itemID: 11]),
            "launcherItemLastUsed": .timestamps([itemID: 1234]),
            "captureEnabled": .boolean(true),
        ], hotkeys: ["fixture": .init(keyCode: 9, modifiers: 0)])
        var expected = original
        expected.values["launcherSelectionUsage"] = .counts([safeKey: 4])

        let filtered = ArchiveSensitivity.filterSettings(original)

        #expect(filtered.settings == expected)
        #expect(filtered.excluded == 1)
        #expect(original.values["launcherSelectionUsage"] == .counts([safeKey: 4, sensitiveKey: 7]))
    }

    @Test func countMapFilteringHandlesPlainSecretKeysAndRetainsEmptyQueryRanking() {
        let safeKey = "\u{1F}" + "app:com.example.archive-fixture"
        let counts = [safeKey: 3, "AKIAIOSFODNN7EXAMPLE": 7]

        #expect(ArchiveSensitivity.filterCountMap(counts) == [safeKey: 3])
        #expect(counts.count == 2)
    }

    @Test func safeSettingsArePreservedExactly() {
        let itemID = "app:com.example.archive-fixture"
        let settings = ClipArchive.Settings(namespace: "archive-privacy-fixture", version: 1, values: [
            "launcherSelectionUsage": .counts(["ordinary search" + "\u{1F}" + itemID: 4]),
            "launcherItemUseCounts": .counts([itemID: 11]),
            "launcherItemLastUsed": .timestamps([itemID: 1234]),
        ])

        let filtered = ArchiveSensitivity.filterSettings(settings)

        #expect(filtered.settings == settings)
        #expect(filtered.excluded == 0)
    }

    @Test func fullySensitiveSelectionUsageRetainsAnEmptyTypedRankingMap() {
        let key = "AKIAIOSFODNN7EXAMPLE" + "\u{1F}" + "app:com.example.archive-fixture"
        let settings = ClipArchive.Settings(namespace: "archive-privacy-fixture", version: 1, values: [
            "launcherSelectionUsage": .counts([key: 4]),
        ])

        let filtered = ArchiveSensitivity.filterSettings(settings)

        #expect(filtered.settings.values["launcherSelectionUsage"] == .counts([:]))
        #expect(filtered.excluded == 1)
    }

    @Test(arguments: ["AKIAIOSFODNN7EXAMPLE", "sk-proj-abc123def456ghi789jkl012"])
    func defaultExportRemovesSecretQueriesFromMixedRankingAndPreservesSafeEntries(query: String) async throws {
        let source = try ArchiveHarness()
        let destination = try ArchiveHarness()
        defer { source.remove(); destination.remove() }
        let item = try await source.text("ordinary archive privacy fixture")
        let itemID = "clip:" + item.id
        let safeKey = "ordinary search" + "\u{1F}" + itemID
        let secretKey = query + "\u{1F}" + itemID
        let settings = ClipArchive.Settings(namespace: "archive-privacy-fixture", version: 1, values: [
            "launcherSelectionUsage": .counts([safeKey: 4, secretKey: 7]),
            "launcherItemUseCounts": .counts([itemID: 11]),
            "launcherItemLastUsed": .timestamps([itemID: 1234]),
        ], hotkeys: ["fixture": .init(keyCode: 9, modifiers: 0)])
        var expected = settings
        expected.values["launcherSelectionUsage"] = .counts([safeKey: 4])

        let summary = try await source.store.export(to: source.archive, settings: settings)
        let settingsData = try Data(contentsOf: source.archive.appendingPathComponent(ClipArchive.settingsFileName))
        let archived = try ClipJSONCoding.archiveDecoder().decode(ClipArchive.Settings.self, from: settingsData)

        #expect(summary.secretsExcluded == 1)
        #expect(archived == expected)
        #expect(settings.values["launcherSelectionUsage"] == .counts([safeKey: 4, secretKey: 7]))
        let files = try #require(FileManager.default.enumerator(
            at: source.archive, includingPropertiesForKeys: [.isRegularFileKey]
        )).allObjects.compactMap { $0 as? URL }
        for file in files
            where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        {
            #expect(try Data(contentsOf: file).range(of: Data(query.utf8)) == nil)
        }

        let imported = try await destination.store.import(from: source.archive)

        #expect(imported.settings == expected)
        #expect(imported.imported == 1)
        #expect(try await destination.store.recent().map(\.id) == [item.id])
    }
}
