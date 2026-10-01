import Foundation
import OverboardCore
@testable import OverboardMac
import Testing

struct ArchivePreferencesAdapterTests {
    private func payload(values: [String: ClipArchive.SettingValue],
                         hotkeys: [String: ClipArchive.Hotkey] = [:]) -> ClipArchive.Settings
    {
        .init(
            namespace: ArchivePreferencesAdapter.namespace,
            version: ArchivePreferencesAdapter.version,
            values: values,
            hotkeys: hotkeys
        )
    }

    @Test func typedPreferenceFamiliesValidateWithoutReadingLiveDefaults() throws {
        let settings = self.payload(values: [
            "historyLimit": .integer(1000), "restoreClipboardAfterPaste": .boolean(true),
            "launcherQuicklinks": .string("docs = https://example.test"), "launcherAppAliases": .string("ed = Editor"),
            "savedSearches": .strings(["kind:text"]), "launcherSelectionUsage": .counts(["query|item": 2]),
            "launcherItemLastUsed": .timestamps(["item": 1234]), "ocrEnabled": .boolean(false),
        ], hotkeys: ["toggleLauncher": .init(keyCode: 49, modifiers: 2048), "toggleDrawer": .init(keyCode: nil)])
        try ArchivePreferencesAdapter.validate(settings)
        try ArchivePreferencesAdapter.validate(self.payload(
            values: [:], hotkeys: ["toggleLauncher": .init(keyCode: 122, modifiers: 131_072)]
        ))
        #expect(try ClipJSONCoding.archiveDecoder().decode(
            ClipArchive.Settings.self,
            from: ClipJSONCoding.archiveEncoder().encode(settings)
        ) == settings)
    }

    @Test func permissionKeysUnknownSchemasAndWrongTypesAreRejected() throws {
        #expect(throws: ClipArchive.Failure.self) {
            try ArchivePreferencesAdapter.validate(self.payload(values: ["accessibilityGranted": .boolean(true)]))
        }
        #expect(throws: ClipArchive.Failure.self) {
            try ArchivePreferencesAdapter.validate(self.payload(values: ["historyLimit": .string("1000")]))
        }
        #expect(throws: ClipArchive.Failure.self) { try ArchivePreferencesAdapter.validate(self.payload(
            values: [:],
            hotkeys: ["toggleLauncher": .init(keyCode: -1)]
        )) }
        #expect(throws: ClipArchive.Failure.self) { try ArchivePreferencesAdapter.validate(self.payload(
            values: [:],
            hotkeys: ["toggleLauncher": .init(keyCode: 49, modifiers: Int.max)]
        )) }
        #expect(throws: ClipArchive.Failure.self) { try ArchivePreferencesAdapter.validate(.init(
            namespace: "other",
            version: 1,
            values: [:]
        )) }
        #expect(throws: ClipArchive.Failure.self) { try ArchivePreferencesAdapter.validate(.init(
            namespace: ArchivePreferencesAdapter.namespace,
            version: 999,
            values: [:]
        )) }
        try ArchivePreferencesAdapter.validate(nil)
    }

    @Test func everyPersistedNonpermissionPreferenceGroupHasAnAllowlistedType() throws {
        var values: [String: ClipArchive.SettingValue] = [
            "historyLimit": .integer(1000), "accessibilityHintsShown": .integer(0),
            "launcherItemLastUsed": .timestamps(["fixture-item": 100]),
        ]
        for name in [
            "restoreClipboardAfterPaste", "launcherFileResults", "launcherClipResults", "launcherSnippetResults",
            "launcherSettingsResults", "launcherNowPlaying", "launcherCalendarEvents", "hasCompletedOnboarding",
            "ocrEnabled", "labelingEnabled",
        ] {
            values[name] = .boolean(false)
        }
        for name in [
            "excludedBundleIDs", "plainTextBundleIDs", "autoTransformRules", "launcherAppAliases", "launcherQuicklinks",
            "fileSearchExclusions", "fileSearchRootsDraft", "fileSearchExclusionsDraft",
        ] {
            values[name] = .string("fixture")
        }
        for name in ["launcherSearchHistory", "fileSearchRoots", "savedSearches", "emojiRecents"] {
            values[name] = .strings(["fixture"])
        }
        for name in ["launcherSelectionUsage", "launcherItemUseCounts"] {
            values[name] = .counts(["fixture-item": 1])
        }
        let hotkeys = Dictionary(uniqueKeysWithValues: [
            "toggleDrawer", "pasteNextFromStack", "toggleLauncher", "toggleEmojiPicker",
        ].map { ($0, ClipArchive.Hotkey(keyCode: nil)) })
        let settings = self.payload(values: values, hotkeys: hotkeys)
        try ArchivePreferencesAdapter.validate(settings)
        let encoded = try ClipJSONCoding.archiveEncoder().encode(settings)
        #expect(try ClipJSONCoding.archiveDecoder().decode(ClipArchive.Settings.self, from: encoded) == settings)
    }
}
