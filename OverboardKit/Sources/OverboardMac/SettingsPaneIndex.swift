import Foundation
import OverboardCore

/// In-memory index of macOS System Settings panes. Modern System Settings
/// (Ventura+) ships each pane as an ExtensionKit app extension; the legacy
/// `/System/Library/PreferencePanes` bundles are partly gutted, so we scan the
/// extensions instead and match on `EXExtensionPointIdentifier`. A scan is a
/// few milliseconds, cached like AppIndex so pane rows render instantly.
@MainActor
public final class SettingsPaneIndex {
    public struct Entry: Sendable, Equatable {
        public let name: String
        /// The `x-apple.systempreferences:<bundle-id>` link that opens the pane.
        public let url: URL

        public init(name: String, url: URL) {
            self.name = name
            self.url = url
        }
    }

    private var cache: [Entry] = []
    private var lastScan: Date?
    private let maxCacheAge: TimeInterval = 300

    public init() {}

    public func entries() async -> [Entry] {
        if let lastScan, Date.now.timeIntervalSince(lastScan) < self.maxCacheAge {
            return self.cache
        }
        let scanned = await Task.detached(priority: .utility) { Self.scan() }.value
        self.cache = scanned
        self.lastScan = .now
        return scanned
    }

    private nonisolated static func scan() -> [Entry] {
        // Modern System Settings ships each pane as an ExtensionKit extension
        // advertising this extension point.
        let extensionsDirectory = URL(
            fileURLWithPath: "/System/Library/ExtensionKit/Extensions", isDirectory: true
        )
        let settingsExtensionPoint = "com.apple.Settings.extension.ui"

        var entries: [Entry] = []
        var seen = Set<String>()
        for url in self.contents(of: extensionsDirectory) where url.pathExtension == "appex" {
            guard let info = self.infoPlist(at: url),
                  let attributes = info["EXAppExtensionAttributes"] as? [String: Any],
                  attributes["EXExtensionPointIdentifier"] as? String == settingsExtensionPoint,
                  let bundleID = info["CFBundleIdentifier"] as? String,
                  seen.insert(bundleID).inserted,
                  let name = self.displayName(for: url, info: info),
                  let link = URL(string: "x-apple.systempreferences:\(bundleID)")
            else { continue }
            entries.append(Entry(name: name, url: link))
        }
        return entries
    }

    /// Prefer the localized display name (resolves raw names like
    /// "MouseExtension" → "Mouse"), then the plist's display name, then the
    /// bundle name. Returns nil when nothing usable is present.
    private nonisolated static func displayName(for url: URL, info: [String: Any]) -> String? {
        let candidates = [
            Bundle(url: url)?.localizedInfoDictionary?["CFBundleDisplayName"] as? String,
            info["CFBundleDisplayName"] as? String,
            info["CFBundleName"] as? String,
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private nonisolated static func infoPlist(at appexURL: URL) -> [String: Any]? {
        let plistURL = appexURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return plist as? [String: Any]
    }

    private nonisolated static func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
    }
}

/// Instant launcher rows for System Settings panes, ranked with the same
/// matcher as app search (prefix, initials like "sd" → "Sound", substring).
public struct SettingsPaneSearchProvider: LauncherProvider {
    private let index: SettingsPaneIndex
    private let limit: Int

    public init(index: SettingsPaneIndex, limit: Int = 5) {
        self.index = index
        self.limit = limit
    }

    public func results(for query: String) async -> [LauncherResult] {
        guard query.count >= 2 else { return [] }
        let entries = await self.index.entries()
        let ranked = AppMatcher.rank(query: query, names: entries.map(\.name), limit: self.limit)
        return ranked.map { .systemSetting(name: entries[$0].name, url: entries[$0].url) }
    }
}
