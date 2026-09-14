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
        calendar: CalendarSource,
        pausedSnapshot: OSAllocatedUnfairLock<Bool>
    ) -> LauncherViewModel {
        let launcherViewModel = LauncherViewModel(
            instantProviders: Self.makeInstantProviders(calendar: calendar),
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
            // "Ask AI" fallback row — only when the on-device model is ready.
            clipboardStore: store,
            askAIProvider: AskAIProvider(isAvailable: { AITransformer.isAvailable })
        )
        // Pin the up-next calendar event and the Spotify now-playing row under
        // every result list, in that order, when each is enabled and has
        // something to show.
        launcherViewModel.pinnedResults = Self.pinnedLauncherResults(spotify: spotify, calendar: calendar)
        return launcherViewModel
    }

    /// Quicklinks, `>` shell commands, apps, system settings panes, system
    /// actions (lock/sleep/restart), audio outputs, and calendar events — every result cheap
    /// enough to compute on each keystroke. Split out of
    /// `makeLauncherViewModel` to keep that initializer readable.
    private static func makeInstantProviders(calendar: CalendarSource) -> [any LauncherProvider] {
        [
            QuicklinkProvider { Quicklink.parse(Defaults[.launcherQuicklinks]) },
            ShellCommandProvider(isAvailable: { GhosttyLauncher.isInstalled() }),
            AppSearchProvider(index: AppIndex(), limit: 60) {
                AppMatcher.parseAliases(Defaults[.launcherAppAliases])
            },
            ConditionalProvider(SettingsPaneSearchProvider(index: SettingsPaneIndex())) {
                Defaults[.launcherSettingsResults]
            },
            ConditionalProvider(SystemActionProvider(
                isAvailable: { $0 != .lockScreen || SystemActionService.canLockScreen }
            )) {
                Defaults[.launcherSettingsResults]
            },
            ConditionalProvider(AudioOutputSearchProvider(
                devices: { AudioOutputService.shared.devices() }
            )) {
                Defaults[.launcherSettingsResults]
            },
            self.calendarEventsProvider(calendar: calendar),
        ]
    }

    /// The launcher's `cal`/`calendar`/`today`/`tomorrow`/`meetings`/`events`
    /// instant provider. Demo mode reads `DemoSeed`'s fake events and reports
    /// itself always-authorized (never touches EventKit); the real build reads
    /// `CalendarSource`'s live snapshot and its actual authorization state.
    private static func calendarEventsProvider(calendar: CalendarSource) -> ConditionalProvider {
        isDemo
            ? ConditionalProvider(UpcomingEventsProvider(
                events: { DemoSeed.calendarEvents(now: .now) },
                isAuthorized: { true }
            )) { Defaults[.launcherCalendarEvents] }
            : ConditionalProvider(UpcomingEventsProvider(
                events: { calendar.snapshot.withLock { $0 } },
                isAuthorized: { CalendarSource.authorization == .granted }
            )) { Defaults[.launcherCalendarEvents] }
    }

    /// The pinned-footer rows: the up-next calendar event, then the Spotify
    /// now-playing row, each included only when its toggle is on and it has
    /// something to show. Demo mode pins from `DemoSeed`'s fake events (its
    /// near-term one is deliberately a few minutes out, for screenshots)
    /// instead of the developer's own calendar; the real Spotify monitor is
    /// never started in demo mode, so `spotify.current` is already nil there.
    private static func pinnedLauncherResults(
        spotify: SpotifyNowPlayingMonitor,
        calendar: CalendarSource
    ) -> () -> [LauncherResult] {
        { [spotify] in
            let pinnedEvent: LauncherResult? = {
                guard Defaults[.launcherCalendarEvents] else { return nil }
                let next: CalendarEvent? = Self.isDemo
                    ? Self.nextEvent(in: DemoSeed.calendarEvents(now: .now), now: .now)
                    : (CalendarSource.authorization == .granted ? calendar.nextEvent(now: .now) : nil)
                return next.map { .calendarEvent($0) }
            }()
            let pinnedTrack: LauncherResult? = Defaults[.launcherNowPlaying]
                ? spotify.current.map { .nowPlaying($0) }
                : nil
            return [pinnedEvent, pinnedTrack].compactMap(\.self)
        }
    }

    /// The earliest not-yet-ended event — the same rule `CalendarSource.nextEvent`
    /// applies to its live snapshot, reused here for `DemoSeed`'s fake array.
    private static func nextEvent(in events: [CalendarEvent], now: Date) -> CalendarEvent? {
        events.filter { $0.end > now }.min { $0.start < $1.start }
    }
}
