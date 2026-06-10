import AppKit
import OverboardCore

/// In-memory index of installed applications. A directory scan of the
/// canonical app folders is a few milliseconds for a few hundred bundles —
/// fast enough to make app rows instant, unlike NSMetadataQuery, and it
/// enables matching Spotlight can't do (initials, user aliases).
@MainActor
public final class AppIndex {
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let url: URL
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
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        var entries: [Entry] = []
        var seen = Set<String>()
        for root in roots {
            for url in self.contents(of: root) {
                if url.pathExtension == "app" {
                    if seen.insert(url.path).inserted {
                        entries.append(Entry(name: url.deletingPathExtension().lastPathComponent, url: url))
                    }
                } else if url.hasDirectoryPath {
                    // One level of vendor folders ("/Applications/Adobe …/").
                    for nested in self.contents(of: url) where nested.pathExtension == "app" {
                        if seen.insert(nested.path).inserted {
                            entries.append(Entry(name: nested.deletingPathExtension().lastPathComponent, url: nested))
                        }
                    }
                }
            }
        }
        return entries
    }

    private nonisolated static func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }
}

/// Instant launcher rows for applications: AppMatcher decides what a query
/// hits (prefix, initials like "sm", substring, or a user alias).
public struct AppSearchProvider: LauncherProvider {
    private let index: AppIndex
    private let limit: Int
    private let aliases: @Sendable () -> [String: String]

    public init(index: AppIndex, limit: Int = 5, aliases: @escaping @Sendable () -> [String: String] = { [:] }) {
        self.index = index
        self.limit = limit
        self.aliases = aliases
    }

    public func results(for query: String) async -> [LauncherResult] {
        guard query.count >= 2 else { return [] }
        let entries = await self.index.entries()
        let ranked = AppMatcher.rank(
            query: query,
            names: entries.map(\.name),
            aliases: self.aliases(),
            limit: self.limit
        )
        return ranked.map { .app(name: entries[$0].name, url: entries[$0].url) }
    }
}
