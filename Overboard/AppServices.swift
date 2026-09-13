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
final class AppServices {
    static let shared = AppServices()

    /// Demo mode (`OVERBOARD_DEMO=1`): in-memory store seeded with fake clips,
    /// no clipboard monitoring or global hotkeys. Used by
    /// scripts/demo-screenshots.sh to capture README screenshots without
    /// touching (or leaking) real clipboard history.
    nonisolated static let isDemo = ProcessInfo.processInfo.environment["OVERBOARD_DEMO"] == "1"

    let signal = CaptureSignal()
    let captureState = CaptureState()
    let updates = UpdateChecker()

    let store: ClipStore
    let monitor: ClipboardMonitor
    let pasteback: PastebackService
    /// Post-ingest OCR / link / LLM enrichment, shared by the ingest loop and
    /// the link-backfill job.
    private let enrichment: ClipEnrichmentPipeline
    /// Side effects for `ClipAction`, plus the shared copy/paste helpers the
    /// launcher callbacks and the App Intents (via `copyString`) go through.
    private let actions: ClipActionExecutor
    let overlay: OverlayController
    let launcher: LauncherPanelController
    let spotify: SpotifyNowPlayingMonitor
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

    private var pendingWindowID: String?

    private var ingestTask: Task<Void, Never>?
    /// Purge, secret expiry, blob/VACUUM sweep, and link backfill, as one
    /// start/stop unit.
    private let maintenance: MaintenanceScheduler
    private let logger = Logger(subsystem: "com.nickysemenza.overboard", category: "app")

    private init() {
        do {
            if Self.isDemo {
                let queue = try OverboardDatabase.openInMemory()
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("overboard-demo-\(UUID().uuidString)", isDirectory: true)
                self.store = try ClipStore(dbWriter: queue, blobs: BlobStore(directory: directory))
            } else {
                let directory = try OverboardDatabase.defaultDirectory()
                let pool = try OverboardDatabase.open(at: directory)
                let blobs = try BlobStore(directory: directory.appendingPathComponent("blobs", isDirectory: true))
                self.store = ClipStore(dbWriter: pool, blobs: blobs)
            }
        } catch {
            // `shared` is a `static let`, so this initializer can't fail or
            // return early — every existing `AppServices.shared.x` callsite
            // assumes a working instance. Rather than `fatalError` (which was
            // the previous behavior: any open/migration failure — a corrupted
            // file, a crash-torn WAL, disk-full — silently crashed the whole
            // app with no explanation), fall back to an in-memory store so
            // the rest of `init` can still build a usable (if inert) object
            // graph, then get the user out of the broken state on the next
            // run-loop turn: this initializer runs synchronously from
            // `applicationDidFinishLaunching` (via this lazy `static let`),
            // and presenting a modal alert or calling `NSApp.terminate` before
            // that callback returns can preempt AppKit's own launch
            // bookkeeping — so the alert is deferred rather than shown here.
            self.logger.error("Failed to open Overboard database: \(String(describing: error), privacy: .public)")
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
            self.store = ClipStore(dbWriter: queue, blobs: blobs)
            let openError = error
            DispatchQueue.main.async {
                Self.presentDatabaseOpenFailureAlert(openError)
            }
        }
        self.monitor = ClipboardMonitor()
        self.pasteback = PastebackService(store: self.store)
        self.enrichment = ClipEnrichmentPipeline(store: self.store) {
            ClipEnrichmentPipeline.Settings(
                richLinkPreviews: Defaults[.richLinkPreviews],
                aiFeatures: Defaults[.aiFeatures]
            )
        }
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
        let pausedSnapshot = self.captureState.snapshot
        let store = self.store
        let launcherViewModel = LauncherViewModel(
            instantProviders: [
                AppSearchProvider(index: AppIndex(), limit: 60) {
                    AppMatcher.parseAliases(Defaults[.launcherAppAliases])
                },
                ConditionalProvider(SettingsPaneSearchProvider(index: SettingsPaneIndex())) {
                    Defaults[.launcherSettingsResults]
                },
            ],
            secondaryProviders: [
                ConditionalProvider(SnippetSearchProvider(store: self.store)) {
                    Defaults[.launcherSnippetResults]
                },
                ConditionalProvider(ClipSearchProvider(store: self.store)) {
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
            clipboardStore: self.store,
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
            self.updates.start()
            self.startSpotifyMonitor()
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
        self.updates.stop()
        if !Self.isDemo {
            self.monitor.stop()
            FileIndexService.shared.stop()
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

    /// Clipboard monitoring, ingest, and background maintenance — everything
    /// that touches the real pasteboard or the on-disk database.
    private func startCapturePipeline() {
        self.monitor.excludedBundleIDs = { Preferences.currentExclusions() }
        self.monitor.start()

        let store = store
        let enrichment = self.enrichment
        let snapshots = self.monitor.snapshots
        self.ingestTask = Task(priority: .utility) { [logger] in
            for await snapshot in snapshots {
                do {
                    var snapshot = Self.applyingAutoTransforms(to: snapshot)
                    // Browser copies carry back-to-source provenance: ask the
                    // browser for its front-tab URL/title before storing. Bounded
                    // by the fetch's own ~500ms timeout, and only round-trips at
                    // all when the source app is a scriptable browser.
                    if let bundleID = snapshot.sourceBundleID,
                       BrowserScript.dialect(forBundleID: bundleID) != nil,
                       let provenance = await BrowserProvenanceService.fetch(bundleID: bundleID)
                    {
                        snapshot.sourceURL = provenance.url
                        snapshot.sourceTitle = provenance.title
                    }
                    if let item = try await store.ingest(snapshot) {
                        self.signal.bump()
                        // Fire-and-forget so a slow OCR/LLM pass never delays
                        // capturing the next copy.
                        Task.detached(priority: .utility) {
                            await enrichment.enrich(item: item, snapshot: snapshot)
                        }
                    }
                } catch {
                    logger.error("ingest failed: \(String(describing: error), privacy: .public)")
                }
            }
        }

        self.maintenance.start()
    }

    /// The recurring background chores, as data. `MaintenanceScheduler` owns
    /// the cancel-aware loop and the sleeps; each job just does one pass and
    /// says whether it wants another.
    private nonisolated static func maintenanceJobs(
        store: ClipStore,
        enrichment: ClipEnrichmentPipeline,
        logger: Logger
    ) -> [MaintenanceJob] {
        [
            // Trim history (and orphaned blobs) on launch and hourly thereafter.
            MaintenanceJob(name: "purge", interval: .seconds(3600)) {
                let limit = Defaults[.historyLimit]
                do {
                    try await store.purge(keepingLatest: max(limit, 100))
                } catch {
                    logger.error("purge failed: \(String(describing: error), privacy: .public)")
                }
                return .repeatLater
            },

            // Reclaim orphaned blob files and compact the DB on launch, then
            // daily — after letting launch settle, since the first pass is
            // VACUUM-heavy.
            MaintenanceJob(
                name: "maintenance sweep",
                interval: .seconds(24 * 3600),
                initialDelay: .seconds(30)
            ) {
                do {
                    let result = try await store.maintenanceSweep()
                    if result.orphanedBlobsDeleted > 0 || result.missingBlobs > 0 {
                        logger.info("""
                        maintenance sweep: reclaimed \(result.orphanedBlobsDeleted, privacy: .public) \
                        orphaned blobs, \(result.missingBlobs, privacy: .public) missing
                        """)
                    }
                } catch {
                    logger.error("maintenance sweep failed: \(String(describing: error), privacy: .public)")
                }
                return .repeatLater
            },

            // Backfill rich-link metadata for existing links, once per launch.
            // Starts 60s after launch (let capture/OCR settle first), then drains
            // the queue in small batches with a pause between fetches to stay a
            // polite network citizen. Stops when no links remain; picks up again
            // next launch.
            MaintenanceJob(name: "link backfill", interval: .zero, initialDelay: .seconds(60)) {
                guard Defaults[.richLinkPreviews] else { return .finished }
                let links: [ClipItem]
                do {
                    links = try await store.linksNeedingMetadata(limit: 25)
                } catch {
                    logger.error("link backfill query failed: \(String(describing: error), privacy: .public)")
                    return .finished
                }
                guard !links.isEmpty else { return .finished }
                for link in links {
                    if Task.isCancelled { return .finished }
                    await enrichment.fetchLinkMetadata(for: link)
                    try? await Task.sleep(for: .seconds(1))
                }
                return .repeatLater
            },

            // Detected secrets expire on a short leash, swept every minute.
            MaintenanceJob(name: "secret sweep", interval: .seconds(60)) {
                let ttlMinutes = Defaults[.secretTTLMinutes]
                if ttlMinutes > 0 {
                    let cutoff = Date().addingTimeInterval(-Double(ttlMinutes) * 60)
                    try? await store.purgeExpiredSecrets(olderThan: cutoff)
                }
                return .repeatLater
            },
        ]
    }

    /// Spotify now-playing: observe playback broadcasts, refresh an open panel
    /// on change, and reconcile a fresh snapshot each time the launcher opens.
    private func startSpotifyMonitor() {
        self.spotify.onChange = { [weak self] in
            guard let self, self.launcher.isVisible else { return }
            self.launcher.refreshRows()
        }
        self.spotify.start()
    }

    private func installOverlayCallbacks() {
        self.overlay.onCommit = { [weak self] item, mode, target in
            self?.pasteItem(item, mode: mode, into: target)
        }

        self.overlay.onCommitSnippet = { [weak self] snippet, target in
            guard let self else { return }
            let clipboard = NSPasteboard.general.string(forType: .string)
            let expanded = SnippetTemplate.expand(snippet.body, clipboard: clipboard)
            self.pasteString(expanded, into: target)
        }

        self.overlay.onCommitTransform = { [weak self] item, transform, target in
            guard let self else { return }
            Task {
                guard let text = try? await self.store.plainText(for: item.id) else { return }
                try? await self.store.markUsed(id: item.id)
                self.pasteString(transform.apply(to: text), into: target)
            }
        }

        self.overlay.onCommitEditedText = { [weak self] text, target in
            self?.pasteString(text, into: target)
        }

        self.overlay.onRunAction = { [weak self] action, items, target in
            guard let self else { return }
            Task {
                await self.runAction(action, on: items, target: target)
            }
        }

        self.overlay.onCommitAITransform = { [weak self] item, transform, target in
            guard let self else { return }
            Task {
                guard let text = try? await self.store.plainText(for: item.id) else { return }
                HUDController.shared.flash("✨ \(transform.label)…", duration: .seconds(15))
                do {
                    let result = try await AITransformer.apply(transform, to: text)
                    try? await self.store.markUsed(id: item.id)
                    self.pasteString(result, into: target)
                } catch {
                    HUDController.shared.flash("AI transform failed")
                    self.logger.error("AI transform failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private func installLauncherCallbacks() {
        if !Self.isDemo {
            FileIndexService.shared.onChange = { [weak self] in
                guard let self, self.launcher.isVisible else { return }
                self.launcherViewModel.scheduleSearch(preserveSelection: true)
            }
        }
        self.overlay.onBrowseHistory = { [weak self] query, target in
            self?.launcher.show(scope: .clipboard, query: query, target: target)
        }
        // Summon-time refresh: reconcile the Spotify now-playing snapshot (its
        // onChange only refreshes an open panel, so a missed track change is
        // caught here) and snapshot running apps for the row indicator dots.
        // Observation runs only while the panel is visible.
        self.launcher.onWillShow = { [weak self] in
            guard let self else { return }
            if !Self.isDemo { self.spotify.refreshSnapshot() }
            self.launcherViewModel.runningAppPaths = self.runningApps.snapshot()
            self.runningApps.startObserving()
        }
        self.launcher.onWillHide = { [weak self] in
            self?.runningApps.stopObserving()
        }
        self.runningApps.onChange = { [weak self] in
            guard let self, self.launcher.isVisible else { return }
            self.launcherViewModel.runningAppPaths = self.runningApps.snapshot()
        }
        self.launcher.onCopyText = { [weak self] text in
            self?.copyString(text, hud: "Result copied — ⌘V to paste")
        }
        self.launcher.onPasteText = { [weak self] text, target in
            self?.pasteString(text, into: target)
        }
        self.launcher.onOpenFile = { [weak self] url in
            guard let self else { return }
            let query = self.launcherViewModel.query
            let id = self.launcherViewModel.selectedResult?.id
            Task {
                do {
                    let needsDownload = FileAvailability.status(at: url) == .cloud
                    if needsDownload {
                        HUDController.shared.flash("Downloading \(url.lastPathComponent)…", duration: .seconds(60))
                    }
                    try await FileOpening.open(url)
                    if needsDownload { HUDController.shared.flash("Opened \(url.lastPathComponent)") }
                    if let id { self.launcherViewModel.recordSuccessfulSelection(id: id, query: query) }
                } catch {
                    HUDController.shared.flash("Couldn’t open \(url.lastPathComponent). Check its location or internet connection and try again.", duration: .seconds(6))
                }
            }
        }
        self.launcher.onRevealFile = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        self.launcher.onCopyPath = { [weak self] path in
            self?.copyString(path, hud: "Path copied")
        }
        self.launcher.onOpenWebSearch = { url in
            NSWorkspace.shared.open(url)
        }
        self.launcher.onOpenSystemSetting = { url in
            NSWorkspace.shared.open(url)
        }
        self.launcher.onPasteClip = { [weak self] item, mode, target in
            guard let self else { return }
            let query = self.launcherViewModel.query
            self.pasteItem(item, mode: mode, into: target) { [weak self] in
                self?.launcherViewModel.recordSuccessfulSelection(id: LauncherResult.clip(item).id, query: query)
            }
        }
        self.launcher.onCopyClip = { [weak self] item in
            guard let self else { return }
            Task {
                do {
                    try await self.pasteback.copy(item)
                    HUDController.shared.flash("Copied — ⌘V to paste")
                } catch {
                    self.logger.error("copy failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        self.launcher.onPasteSnippet = { [weak self] snippet, target in
            guard let self else { return }
            // Read {clipboard} before pasteString overwrites the pasteboard.
            let clipboard = NSPasteboard.general.string(forType: .string)
            let expanded = SnippetTemplate.expand(snippet.body, clipboard: clipboard)
            self.pasteString(expanded, into: target)
        }
        self.launcher.onCopySnippet = { [weak self] snippet in
            guard let self else { return }
            let clipboard = NSPasteboard.general.string(forType: .string)
            let expanded = SnippetTemplate.expand(snippet.body, clipboard: clipboard)
            self.copyString(expanded, hud: "Snippet copied — ⌘V to paste")
        }
        self.launcher.onRunCommand = { [weak self] command in
            guard let self else { return }
            switch command {
            case .version, .settings: Self.openSettings()
            // `:stats` has no action of its own — ↩ opens Settings, where the
            // full library breakdown lives (the row subtitle is the summary).
            // Deep-links straight to the History tab via SettingsNavigation.
            case .stats: Self.openSettings(tab: .history)
            case .pause: self.setCapturePaused(true)
            case .resume: self.setCapturePaused(false)
            case .clear: self.confirmAndClearHistory()
            }
        }
        self.launcher.onCopyNowPlayingLink = { [weak self] track in
            let text = track.shareURL?.absoluteString ?? "\(track.title) — \(track.artist)"
            self?.copyString(text, hud: "Spotify link copied — ⌘V to paste")
        }
        self.launcher.onOpenSpotify = { _ in
            let id = SpotifyNowPlayingMonitor.spotifyBundleID
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                app.activate()
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
        self.launcher.onAskAI = { [weak self] prompt, delivery, target in
            guard let self else { return }
            // Read the clipboard text now — the launcher captured `target`
            // before hiding, so a paste lands back in the originating app.
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
                HUDController.shared.flash("Clipboard is empty")
                return
            }
            Task {
                HUDController.shared.flash("✨ Thinking…", duration: .seconds(15))
                do {
                    let result = try await AITransformer.apply(prompt: prompt, to: text)
                    switch delivery {
                    case .paste: self.pasteString(result, into: target)
                    case .copy: self.copyString(result, hud: "Copied — ⌘V to paste")
                    }
                } catch {
                    HUDController.shared.flash("AI transform failed")
                    self.logger.error("Ask AI failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        self.launcher.onQuitApp = { url in
            // Match the running instance by its bundle URL and ask it to quit.
            NSWorkspace.shared.runningApplications
                .first { $0.bundleURL == url }?
                .terminate()
        }
        self.launcher.onOpenClipLink = { url in
            NSWorkspace.shared.open(url)
        }
    }

    private func installEmojiCallbacks() {
        // Both paths reuse the shared clipboard plumbing: marker tagging keeps
        // the emoji out of history, and paste falls back to copy-only + HUD
        // without Accessibility.
        self.emojiPicker.onPaste = { [weak self] emoji, target in
            self?.pasteString(emoji, into: target)
        }
        self.emojiPicker.onCopy = { [weak self] emoji in
            self?.copyString(emoji, hud: "Copied — ⌘V to paste")
        }
    }

    /// The Welcome window's scene id, shared by the first-run open and the
    /// menu item that reopens it.
    static let welcomeWindowID = "welcome"

    /// Shows Welcome on the very first launch. A menu-bar app has nothing else
    /// to show a new user, so this is their only introduction; every later
    /// launch skips it and the menu item reopens it on demand.
    func showWelcomeIfNeeded() {
        guard !Defaults[.hasCompletedOnboarding] else { return }
        self.showWindow(id: Self.welcomeWindowID)
    }

    /// Raises one of the app's `Window` scenes, queuing the request when
    /// SwiftUI hasn't handed us `openWindow` yet.
    func showWindow(id: String) {
        guard let open = self.openWindowByID else {
            self.pendingWindowID = id
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        open(id)
    }

    /// SwiftUI's stable identifier for the `Settings` scene's window.
    private static let settingsWindowID = "com_apple_SwiftUI_Settings_window"

    /// Pops the Settings scene from a menu-bar (LSUIElement) app — harder than it
    /// looks. The launcher is a non-activating panel, so when this fires the app
    /// is in the background, and a background accessory app can't self-activate
    /// on Sonoma (`NSApp.activate` no-ops). So:
    ///   - If the window doesn't exist (or was closed), build/re-show it via the
    ///     main menu's ⌘, key-equivalent — the one path that materializes the
    ///     SwiftUI Settings scene from our background state.
    ///   - Then `orderFrontRegardless` raises it even while we're inactive, which
    ///     is the only thing that works when Settings is already open behind
    ///     another app (⌘, / showSettingsWindow: both no-op in that case).
    ///
    /// `tab` deep-links into a specific tab via the shared `SettingsNavigation`
    /// object bound into the `SettingsView`'s `TabView` selection.
    static func openSettings(tab: SettingsTab = .general) {
        self.shared.settingsNavigation.selectedTab = tab
        NSApp.activate(ignoringOtherApps: true)
        let existing = self.settingsWindow()
        if existing == nil || existing?.isVisible == false {
            // keyCode 0x2B = ",".
            if let comma = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: 0, context: nil,
                characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 0x2B
            ) {
                NSApp.mainMenu?.performKeyEquivalent(with: comma)
            }
        }
        // Deferred so a just-created window is in `NSApp.windows` by now.
        DispatchQueue.main.async {
            guard let settings = settingsWindow() else { return }
            settings.makeKeyAndOrderFront(nil)
            settings.orderFrontRegardless()
        }
    }

    private static func settingsWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == self.settingsWindowID }
    }

    /// Surfaces a database open/migration failure the way the CLI already
    /// does for a reader that hits a bad database (see
    /// `OverboardDatabase.ReadOnlyOpenError` and `OverboardCLI.Main`'s
    /// read-error handling): plain-language recovery guidance plus a way to
    /// get at the file, rather than the silent crash a `fatalError` gave. The
    /// app is already running on the in-memory fallback store by the time
    /// this shows, so there's nothing to lose by explaining and quitting.
    private static func presentDatabaseOpenFailureAlert(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Overboard couldn't open its database"
        alert.informativeText = """
        \(error.localizedDescription)

        This usually means the database file is corrupted or was left mid-write \
        by a crash. Overboard can't run without it and will quit — moving the \
        database file aside and relaunching starts fresh (losing clipboard \
        history), or you can back it up first for support.
        """
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn, let directory = try? OverboardDatabase.defaultDirectory() {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        }
        NSApp.terminate(nil)
    }

    // MARK: - Capture pause / resume

    /// Pauses or resumes clipboard capture. Drives both `:pause`/`:resume` and
    /// the menu-bar toggle, and flips `captureState` so the menu-bar icon and
    /// the command list (`:pause` vs `:resume`) stay in sync. No-op in demo
    /// mode, where the monitor is never started.
    func setCapturePaused(_ paused: Bool) {
        guard !Self.isDemo, self.captureState.isPaused != paused else { return }
        self.captureState.setPaused(paused)
        if paused {
            self.monitor.stop()
            HUDController.shared.flash("Clipboard capture paused")
        } else {
            self.monitor.start()
            HUDController.shared.flash("Clipboard capture resumed")
        }
    }

    /// `:clear` — confirm, then wipe all history (pinned items survive `purge`).
    /// The launcher panel has already hidden itself by the time `onRunCommand`
    /// fires, so the modal alert isn't stacked over the non-activating launcher.
    private func confirmAndClearHistory() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = ClearHistoryPrompt.title
        alert.informativeText = ClearHistoryPrompt.message
        alert.addButton(withTitle: ClearHistoryPrompt.confirm)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                try await self.store.purge(keepingLatest: 0)
                HUDController.shared.flash("Clipboard history cleared")
            } catch {
                self.logger.error("clear history failed: \(String(describing: error), privacy: .public)")
                HUDController.shared.flash("Couldn't clear history")
            }
        }
    }

    private func registerHotkeys() {
        HotkeyService.onToggleDrawer { [weak self] in
            self?.overlay.toggle()
        }

        HotkeyService.onToggleLauncher { [weak self] in
            self?.launcher.toggle()
        }

        HotkeyService.onToggleEmojiPicker { [weak self] in
            self?.emojiPicker.toggle()
        }

        HotkeyService.onPasteNextFromStack { [weak self] in
            guard let self else { return }
            guard let item = self.stack.popNext() else {
                HUDController.shared.flash("Paste stack is empty")
                return
            }
            let remaining = self.stack.count
            self.pasteItem(item, mode: .full, into: NSWorkspace.shared.frontmostApplication) {
                if remaining > 0 {
                    HUDController.shared.flash("Pasted from stack — \(remaining) left")
                }
            }
        }
    }

    /// Applies the user's auto-transform-on-copy rules to a snapshot's
    /// plain-text representation before it's stored, so e.g. tracking params are
    /// stripped from browser URLs at capture. Rich (RTF/HTML) reps are left
    /// alone; only the plain-text flavor — which is what the transforms target
    /// and what these rules exist to normalize — is rewritten. No matching rule
    /// (the common case) returns the snapshot untouched.
    private nonisolated static func applyingAutoTransforms(to snapshot: PasteboardSnapshot) -> PasteboardSnapshot {
        let rules = Preferences.currentAutoTransformRules()
        guard !rules.isEmpty,
              let index = snapshot.reps.firstIndex(where: { $0.uti == WellKnownUTI.plainText }),
              let text = String(data: snapshot.reps[index].data, encoding: .utf8),
              let transformed = AutoTransform.apply(to: text, bundleID: snapshot.sourceBundleID, rules: rules)
        else { return snapshot }

        var adjusted = snapshot
        adjusted.reps[index].data = Data(transformed.utf8)
        return adjusted
    }

    /// Runs one action's side effects against the current selection.
    private func runAction(_ action: ClipAction, on items: [ClipItem], target: NSRunningApplication?) async {
        await self.actions.run(action, on: items, target: target)
    }

    /// Marker-tagged copy + HUD. Internal (not private) so the App Intents in
    /// Intents/ can reuse the same copy path.
    func copyString(_ text: String, hud: String) {
        self.actions.copyString(text, hud: hud)
    }

    private func pasteString(_ text: String, into target: NSRunningApplication?) {
        self.actions.pasteString(text, into: target)
    }

    /// Shared paste path: applies per-app plain-text rules, falls back to
    /// copy-only + HUD when Accessibility isn't granted.
    private func pasteItem(
        _ item: ClipItem,
        mode: PasteMode,
        into target: NSRunningApplication?,
        onPasted: (@MainActor () -> Void)? = nil
    ) {
        Task {
            do {
                var effectiveMode = mode
                if effectiveMode == .full,
                   item.kind == .text || item.kind == .link,
                   let bundleID = target?.bundleIdentifier,
                   Preferences.currentPlainTextApps().contains(bundleID)
                {
                    effectiveMode = .plainText
                }
                let restore = Defaults[.restoreClipboard]
                let outcome = try await self.pasteback.paste(
                    item, into: target, restoreClipboard: restore, mode: effectiveMode
                )
                switch outcome {
                case .pasted:
                    onPasted?()
                case .copiedOnly:
                    HUDController.shared.flash(PermissionService.copyOnlyPasteMessage())
                    PermissionService.promptIfNeeded()
                }
            } catch {
                self.logger.error("paste failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
