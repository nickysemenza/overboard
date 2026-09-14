import AppKit
import os
import OverboardCore
import OverboardMac
import OverboardUI

/// Factories used once, from `AppServices.init()`, kept out of the initializer
/// itself so it stays readable as a list of "assign this property" steps.
extension AppServices {
    /// Opens the on-disk store, falling back to an in-memory one (and
    /// deferring a recovery alert) if the database can't be opened.
    ///
    /// `shared` is a `static let`, so this can't fail or return early — every
    /// existing `AppServices.shared.x` callsite assumes a working instance.
    /// Rather than `fatalError` (which was the previous behavior: any
    /// open/migration failure — a corrupted file, a crash-torn WAL, disk-full
    /// — silently crashed the whole app with no explanation), fall back to an
    /// in-memory store so the rest of `init` can still build a usable (if
    /// inert) object graph, then get the user out of the broken state on the
    /// next run-loop turn: `init` runs synchronously from
    /// `applicationDidFinishLaunching` (via this lazy `static let`), and
    /// presenting a modal alert or calling `NSApp.terminate` before that
    /// callback returns can preempt AppKit's own launch bookkeeping — so the
    /// alert is deferred rather than shown here.
    static func openStore(logger: Logger) -> ClipStore {
        do {
            if isDemo {
                let queue = try OverboardDatabase.openInMemory()
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("overboard-demo-\(UUID().uuidString)", isDirectory: true)
                return try ClipStore(dbWriter: queue, blobs: BlobStore(directory: directory))
            } else {
                let directory = try OverboardDatabase.defaultDirectory()
                let pool = try OverboardDatabase.open(at: directory)
                let blobs = try BlobStore(directory: directory.appendingPathComponent("blobs", isDirectory: true))
                return ClipStore(dbWriter: pool, blobs: blobs)
            }
        } catch {
            logger.error("Failed to open Overboard database: \(String(describing: error), privacy: .public)")
            let fallbackDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("overboard-fallback-\(UUID().uuidString)", isDirectory: true)
            guard let queue = try? OverboardDatabase.openInMemory(),
                  let blobs = try? BlobStore(directory: fallbackDirectory)
            else {
                // No I/O is involved in either fallback, so this is not a
                // realistic failure — but `store` must end up initialized one
                // way or another for `self` to exist at all.
                fatalError("Failed to open Overboard database, and the in-memory fallback also failed: \(error)")
            }
            let openError = error
            DispatchQueue.main.async {
                Self.presentDatabaseOpenFailureAlert(openError)
            }
            return ClipStore(dbWriter: queue, blobs: blobs)
        }
    }

    /// Builds the launcher's view model: every result provider, the command
    /// palette's inclusion/subtitle rules, and the pinned Spotify row.
    static func makeLauncherViewModel(
        store: ClipStore,
        spotify: SpotifyNowPlayingMonitor,
        pausedSnapshot: OSAllocatedUnfairLock<Bool>
    ) -> LauncherViewModel {
        let launcherViewModel = LauncherViewModel(
            instantProviders: [
                QuicklinkProvider { Quicklink.parse(Defaults[.launcherQuicklinks]) },
                ShellCommandProvider(isAvailable: { GhosttyLauncher.isInstalled() }),
                AppSearchProvider(index: AppIndex(), limit: 60) {
                    AppMatcher.parseAliases(Defaults[.launcherAppAliases])
                },
                ConditionalProvider(SettingsPaneSearchProvider(index: SettingsPaneIndex())) {
                    Defaults[.launcherSettingsResults]
                },
            ],
            secondaryProviders: [
                ConditionalProvider(SnippetSearchProvider(store: store)) {
                    Defaults[.launcherSnippetResults]
                },
                ConditionalProvider(ClipSearchProvider(store: store)) {
                    Defaults[.launcherClipResults]
                },
                // Demo screenshots must not leak real home-folder files.
                Self.isDemo
                    ? DemoSeed.LauncherFiles()
                    : ConditionalProvider(IndexedFileSearchProvider(service: FileIndexService.shared)) {
                        Defaults[.launcherFileResults]
                    },
            ],
            // `isIncluded` runs off the main actor (inside QueryRouter's task
            // group), so it reads the lock-backed paused snapshot rather than
            // the main-actor `isPaused`. The store lookup is a normal await.
            commandProvider: CommandProvider(
                isIncluded: { command in
                    let paused = pausedSnapshot.withLock { $0 }
                    switch command {
                    // Only one of pause/resume applies at a time.
                    case .pause: return !paused
                    case .resume: return paused
                    default: return true
                    }
                },
                dynamicSubtitle: { command in
                    guard command == .stats else { return nil }
                    guard let stats = try? await store.libraryStats() else { return nil }
                    return stats.subtitle
                }
            ),
            // "Ask AI" fallback row — only when the on-device model is ready and
            // the user hasn't turned AI features off.
            clipboardStore: store,
            askAIProvider: AskAIProvider(
                isAvailable: { AITransformer.isAvailable && Defaults[.aiFeatures] }
            )
        )
        // Pin the Spotify now-playing row under every result list when enabled
        // and a track is present. The monitor stays nil in demo mode (never
        // started), so screenshots never leak listening.
        launcherViewModel.pinnedResults = { [spotify] in
            guard Defaults[.launcherNowPlaying], let track = spotify.current else { return [] }
            return [.nowPlaying(track)]
        }
        return launcherViewModel
    }
}
