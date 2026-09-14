import AppKit
import os
import OverboardCore
import OverboardMac
import OverboardUI

/// Observable capture counter so the menu bar boat can bounce on each capture.
@Observable
final class CaptureSignal {
    private(set) var count = 0
    func bump() {
        self.count += 1
    }
}

/// Whether clipboard capture is paused (via `:pause` or the menu-bar toggle).
/// Session-only — deliberately NOT persisted, so a relaunch always resumes
/// capturing and the user can't get stuck with a silently-off clipboard.
///
/// The `@Observable`, main-actor `isPaused` drives the UI (menu-bar icon and
/// toggle). `snapshot` mirrors the same value behind a lock so the launcher's
/// `CommandProvider.isIncluded` — a `@Sendable` closure that runs off the main
/// actor inside a task group — can read it without hopping actors. `setPaused`
/// is the single writer that keeps the two in sync.
@Observable
final class CaptureState {
    private(set) var isPaused = false
    /// Thread-safe mirror of `isPaused`, readable from any executor.
    nonisolated let snapshot = OSAllocatedUnfairLock(initialState: false)

    func setPaused(_ paused: Bool) {
        self.isPaused = paused
        self.snapshot.withLock { $0 = paused }
    }
}

/// Composition root: owns the store, monitor, overlay, hotkey, and paste-back.
///
/// Split across extensions in this directory by responsibility:
/// `AppServices+Init.swift` (the store/launcher-view-model factories used
/// below), `AppServices+Capture.swift` (clipboard capture, maintenance jobs,
/// Spotify), `AppServices+Callbacks.swift` (wiring the overlay/launcher/emoji
/// panels), `AppServices+Windows.swift` (Welcome/Settings window plumbing),
/// `AppServices+Hotkeys.swift`, and `AppServices+Actions.swift` (the shared
/// copy/paste helpers).
final class AppServices {
    static let shared = AppServices()

    /// Demo mode (`OVERBOARD_DEMO=1`): in-memory store seeded with fake clips,
    /// no clipboard monitoring or global hotkeys. Used by
    /// scripts/demo-screenshots.sh to capture README screenshots without
    /// touching (or leaking) real clipboard history.
    nonisolated static let isDemo = ProcessInfo.processInfo.environment["OVERBOARD_DEMO"] == "1"

    let signal = CaptureSignal()
    let captureState = CaptureState()

    let store: ClipStore
    let monitor: ClipboardMonitor
    let pasteback: PastebackService
    /// One long-lived fetcher (see `ClipEnrichmentPipeline.linkFetcher`'s
    /// comment on why per-fetch instances leak) wired to the app's
    /// `cloudflared`-backed Access token lookup, so a link behind Cloudflare
    /// Access gets its real title instead of the login page's.
    let linkFetcher = LinkMetadataFetcher(accessToken: { url in
        await CloudflaredAccessTokens.shared.token(for: url)
    })
    /// Post-ingest OCR / link / LLM enrichment, shared by the ingest loop and
    /// the link-backfill job.
    let enrichment: ClipEnrichmentPipeline
    /// Side effects for `ClipAction`, plus the shared copy/paste helpers the
    /// launcher callbacks and the App Intents (via `copyString`) go through.
    let actions: ClipActionExecutor
    let overlay: OverlayController
    let launcher: LauncherPanelController
    let spotify: SpotifyNowPlayingMonitor
    let calendar: CalendarSource
    let launcherViewModel: LauncherViewModel
    let emojiPicker: EmojiPanelController
    let emojiViewModel: EmojiPickerViewModel
    /// Shared Settings tab selection so `openSettings(tab:)` can deep-link
    /// into a specific tab of the once-built `Settings` scene.
    let settingsNavigation = SettingsNavigation()
    let runningApps = RunningApps()
    let stack = PasteStack()

    /// SwiftUI hands out `openWindow` only inside a view, but whether to show
    /// the Welcome window is decided in `applicationDidFinishLaunching`, before
    /// any of our windows exist. The menu-bar label — the one view SwiftUI
    /// renders at launch — installs this, and anything asked for earlier is
    /// flushed the moment it arrives.
    var openWindowByID: ((String) -> Void)? {
        didSet {
            guard let pending = self.pendingWindowID else { return }
            self.pendingWindowID = nil
            self.showWindow(id: pending)
        }
    }

    var pendingWindowID: String?

    var ingestTask: Task<Void, Never>?
    /// Purge, secret expiry, blob/VACUUM sweep, and link backfill, as one
    /// start/stop unit.
    let maintenance: MaintenanceScheduler
    let logger = Logger(subsystem: "com.nickysemenza.overboard", category: "app")

    private init() {
        self.store = Self.openStore(logger: self.logger)
        self.monitor = ClipboardMonitor()
        self.pasteback = PastebackService(store: self.store)
        let linkFetcher = self.linkFetcher
        self.enrichment = ClipEnrichmentPipeline(
            store: self.store,
            settings: { ClipEnrichmentPipeline.Settings(richLinkPreviews: Defaults[.richLinkPreviews]) },
            fetchLink: { await linkFetcher.fetch($0) }
        )
        let stack = self.stack
        self.actions = ClipActionExecutor(
            store: self.store,
            pasteback: self.pasteback,
            flash: { HUDController.shared.flash($0) },
            addToStack: { items in
                for item in items {
                    stack.push(item)
                }
            }
        )
        self.maintenance = MaintenanceScheduler(
            jobs: Self.maintenanceJobs(store: self.store, enrichment: self.enrichment, logger: self.logger)
        )
        self.overlay = OverlayController(store: self.store, stack: self.stack)
        let spotify = SpotifyNowPlayingMonitor()
        self.spotify = spotify
        let calendar = CalendarSource()
        self.calendar = calendar

        let launcherViewModel = Self.makeLauncherViewModel(
            store: self.store,
            spotify: spotify,
            calendar: calendar,
            pausedSnapshot: self.captureState.snapshot
        )
        self.launcherViewModel = launcherViewModel
        self.launcher = LauncherPanelController(store: self.store, viewModel: launcherViewModel)

        // The render check drops emoji newer than the installed system font,
        // so the grid never shows tofu on older macOS.
        let emojiViewModel = EmojiPickerViewModel(
            catalog: { EmojiCatalog.load(isRenderable: EmojiRenderCheck.canRender) }
        )
        self.emojiViewModel = emojiViewModel
        self.emojiPicker = EmojiPanelController(viewModel: emojiViewModel)
    }

    func start() {
        if Self.isDemo {
            // No monitor, purge, secret sweep, or hotkeys: nothing real may be
            // captured, and global hotkeys would fight a concurrently running
            // daily-driver instance.
            Task { await DemoSeed.populate(self.store) }
        } else {
            FileIndexService.shared.start()
            self.startCapturePipeline()
            self.registerHotkeys()
            self.startSpotifyMonitor()
            self.startCalendarSource()
        }

        self.installOverlayCallbacks()
        self.installLauncherCallbacks()
        self.installEmojiCallbacks()
        // Decode the emoji dataset off-main now so the first ⌃⌘Space is instant.
        self.emojiViewModel.warm()
    }

    /// Cancels every background task and stops the OS-facing services started
    /// in `start()`, then gives any in-flight paste-back restore a bounded
    /// chance to hand the user's real clipboard back before the process
    /// exits. Called from `AppDelegate.applicationWillTerminate`.
    func stop() {
        self.ingestTask?.cancel()
        self.maintenance.stop()
        if !Self.isDemo {
            self.monitor.stop()
            FileIndexService.shared.stop()
            self.calendar.stop()
        }

        // `applicationWillTerminate` is synchronous, so the async drain below
        // is bridged onto this thread rather than simply awaited. A hard
        // `DispatchSemaphore.wait()` alone would deadlock: `drain()` awaits a
        // `Task { @MainActor in … }` (the in-flight restore in
        // `PastebackService`), and that job can only run once the main
        // dispatch queue gets to dequeue it — which a blocking wait on the
        // main thread never allows. Spinning the run loop between polls keeps
        // servicing that queue while we wait, bounded to 1s so a stuck paste
        // target (wrong app focused, swallowed keystroke) never hangs quit.
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await self.pasteback.drain()
            semaphore.signal()
        }
        let deadline = Date().addingTimeInterval(1)
        while semaphore.wait(timeout: .now()) == .timedOut, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}
