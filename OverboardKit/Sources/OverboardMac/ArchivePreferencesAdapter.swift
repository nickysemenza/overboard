import Defaults
import Foundation
import KeyboardShortcuts
import OverboardCore

public enum ArchivePreferencesAdapter {
    public nonisolated static let namespace = "com.nickysemenza.overboard.preferences"
    public nonisolated static let version = 1
    public static let didApplyNotification = Notification.Name("OverboardArchivePreferencesDidApply")

    private nonisolated static let booleanNames: Set<String> = [
        "restoreClipboardAfterPaste", "launcherFileResults", "launcherClipResults",
        "launcherSnippetResults", "launcherSettingsResults", "launcherNowPlaying",
        "launcherCalendarEvents", "hasCompletedOnboarding", "ocrEnabled", "labelingEnabled",
    ]
    private nonisolated static let stringNames: Set<String> = [
        "excludedBundleIDs", "plainTextBundleIDs", "autoTransformRules", "launcherAppAliases",
        "launcherQuicklinks", "fileSearchExclusions", "fileSearchRootsDraft", "fileSearchExclusionsDraft",
    ]
    private nonisolated static let arrayNames: Set<String> = [
        "launcherSearchHistory", "fileSearchRoots", "savedSearches", "emojiRecents",
    ]
    private nonisolated static let countNames: Set<String> = ["launcherSelectionUsage", "launcherItemUseCounts"]
    private nonisolated static let shortcutNames: Set<String> = [
        "toggleDrawer", "pasteNextFromStack", "toggleLauncher", "toggleEmojiPicker",
    ]
    private static let booleanKeys: [Defaults.Key<Bool>] = [
        .restoreClipboard, .launcherFileResults, .launcherClipResults, .launcherSnippetResults,
        .launcherSettingsResults, .launcherNowPlaying, .launcherCalendarEvents, .hasCompletedOnboarding,
        Defaults.Key<Bool>("ocrEnabled", default: true, suite: AppPreferenceStorage.suite),
        Defaults.Key<Bool>("labelingEnabled", default: true, suite: AppPreferenceStorage.suite),
    ]
    private static let integerKeys: [Defaults.Key<Int>] = [.historyLimit, .accessibilityHintsShown]
    private static let stringKeys: [Defaults.Key<String>] = [
        .excludedBundleIDs, .plainTextBundleIDs, .autoTransformRules, .launcherAppAliases,
        .launcherQuicklinks, .fileSearchExclusions, .fileSearchRootsDraft, .fileSearchExclusionsDraft,
    ]
    private static let arrayKeys: [Defaults.Key<[String]>] = [
        .launcherSearchHistory, .fileSearchRoots, .savedSearches, .emojiRecents,
    ]
    private static let countKeys: [Defaults.Key<[String: Int]>] = [.launcherSelectionUsage, .launcherItemUseCounts]

    public static func capture() -> ClipArchive.Settings {
        var values: [String: ClipArchive.SettingValue] = [
            "launcherItemLastUsed": .timestamps(Defaults[.launcherItemLastUsed]),
        ]
        for key in self.booleanKeys {
            values[key.name] = .boolean(Defaults[key])
        }
        for key in self.integerKeys {
            values[key.name] = .integer(Defaults[key])
        }
        for key in self.stringKeys {
            values[key.name] = .string(Defaults[key])
        }
        for key in self.arrayKeys {
            values[key.name] = .strings(Defaults[key])
        }
        for key in self.countKeys {
            values[key.name] = .counts(Defaults[key])
        }
        let hotkeys = Dictionary(uniqueKeysWithValues: self.shortcutNames.map { name in
            let shortcut = KeyboardShortcuts.getShortcut(for: KeyboardShortcuts.Name(name))
            return (
                name,
                ClipArchive.Hotkey(keyCode: shortcut?.carbonKeyCode, modifiers: shortcut?.carbonModifiers ?? 0)
            )
        })
        return .init(namespace: self.namespace, version: self.version, values: values, hotkeys: hotkeys)
    }

    public nonisolated static func validate(_ settings: ClipArchive.Settings?) throws {
        guard let settings else { return }
        guard settings.namespace == self.namespace, settings.version == self.version else {
            throw ClipArchive.Failure.invalid("unsupported app preference schema")
        }
        for (name, value) in settings.values {
            guard self.isValid(value, named: name) else {
                throw ClipArchive.Failure.invalid("unsupported preference or type: \(name)")
            }
        }
        for (name, shortcut) in settings.hotkeys {
            try self.validate(shortcut, named: name)
        }
    }

    private nonisolated static func isValid(_ value: ClipArchive.SettingValue, named name: String) -> Bool {
        switch value {
        case .boolean: self.booleanNames.contains(name)
        case let .integer(number):
            (name == "historyLimit" && (1 ... 100_000).contains(number))
                || (name == "accessibilityHintsShown" && (0 ... 1_000_000).contains(number))
        case let .string(text): self.stringNames.contains(name) && text.utf8.count <= 1_000_000
        case let .strings(strings):
            self.arrayNames.contains(name) && strings.count <= 10000
                && strings.allSatisfy { $0.utf8.count <= 100_000 }
        case let .counts(counts):
            self.countNames.contains(name) && counts.count <= 100_000
                && counts.allSatisfy { $0.key.utf8.count <= 4096 && (0 ... Int.max / 2).contains($0.value) }
        case let .timestamps(timestamps):
            name == "launcherItemLastUsed" && timestamps.count <= 100_000
                && timestamps.allSatisfy { $0.key.utf8.count <= 4096 && $0.value.isFinite && $0.value >= 0 }
        }
    }

    private nonisolated static func validate(_ shortcut: ClipArchive.Hotkey, named name: String) throws {
        let normalized = KeyboardShortcuts.Shortcut(
            carbonKeyCode: shortcut.keyCode ?? 0, carbonModifiers: shortcut.modifiers
        )
        guard self.shortcutNames.contains(name), (shortcut.keyCode.map { (0 ... 127).contains($0) } ?? true),
              shortcut.modifiers >= 0, normalized.carbonModifiers == shortcut.modifiers,
              shortcut.keyCode != nil || shortcut.modifiers == 0
        else {
            throw ClipArchive.Failure.invalid("hotkey: \(name)")
        }
    }

    public static func apply(_ settings: ClipArchive.Settings?, onApplied: () -> Void = {}) throws {
        try self.validate(settings)
        guard let settings else { return }
        for (name, value) in settings.values {
            self.apply(value, named: name)
        }
        for (name, shortcut) in settings.hotkeys {
            let value = shortcut.keyCode.map { KeyboardShortcuts.Shortcut(
                carbonKeyCode: $0,
                carbonModifiers: shortcut.modifiers
            ) }
            KeyboardShortcuts.setShortcut(value, for: KeyboardShortcuts.Name(name))
        }
        onApplied()
        NotificationCenter.default.post(name: self.didApplyNotification, object: nil)
    }

    private static func apply(_ value: ClipArchive.SettingValue, named name: String) {
        switch value {
        case let .boolean(value): self.set(value, named: name, in: self.booleanKeys)
        case let .integer(value): self.set(value, named: name, in: self.integerKeys)
        case let .string(value): self.set(value, named: name, in: self.stringKeys)
        case let .strings(value): self.set(value, named: name, in: self.arrayKeys)
        case let .counts(value): self.set(value, named: name, in: self.countKeys)
        case let .timestamps(value): Defaults[.launcherItemLastUsed] = value
        }
    }

    private static func set<Value: Defaults.Serializable>(_ value: Value, named name: String,
                                                          in keys: [Defaults.Key<Value>])
    {
        if let key = keys.first(where: { $0.name == name }) {
            Defaults[key] = value
        }
    }
}
