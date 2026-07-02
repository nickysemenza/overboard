import AppKit
import os
import OverboardCore
import OverboardMac
import OverboardUI

/// Observable capture counter so the menu bar boat can bounce on each capture.
@MainActor
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
@MainActor
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
@MainActor
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
    let overlay: OverlayController
    let launcher: LauncherPanelController
    let spotify: SpotifyNowPlayingMonitor
    let stack = PasteStack()

    private var ingestTask: Task<Void, Never>?
    private var purgeTask: Task<Void, Never>?
    private var secretSweepTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var linkBackfillTask: Task<Void, Never>?
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
            // Without a database there is no app; surface loudly in dev.
            fatalError("Failed to open Overboard database: \(error)")
        }
        self.monitor = ClipboardMonitor()
        self.pasteback = PastebackService(store: self.store)
        self.overlay = OverlayController(store: self.store, stack: self.stack)
        let spotify = SpotifyNowPlayingMonitor()
        self.spotify = spotify
        let pausedSnapshot = self.captureState.snapshot
        let store = self.store
        let launcherViewModel = LauncherViewModel(
            instantProviders: [
                AppSearchProvider(index: AppIndex(), limit: 5) {
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
                    : ConditionalProvider(FileSearchProvider(search: SpotlightFileSearch(), limit: 8)) {
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
                    return Self.statsSubtitle(stats)
                }
            )
        )
        // Pin the Spotify now-playing row under every result list when enabled
        // and a track is present. The monitor stays nil in demo mode (never
        // started), so screenshots never leak listening.
        launcherViewModel.pinnedResults = { [spotify] in
            guard Defaults[.launcherNowPlaying], let track = spotify.current else { return [] }
            return [.nowPlaying(track)]
        }
        self.launcher = LauncherPanelController(store: self.store, viewModel: launcherViewModel)
    }

    func start() {
        if Self.isDemo {
            // No monitor, purge, secret sweep, or hotkeys: nothing real may be
            // captured, and global hotkeys would fight a concurrently running
            // daily-driver instance.
            Task { await DemoSeed.populate(self.store) }
        } else {
            self.startCapturePipeline()
            self.registerHotkeys()
            self.updates.start()
            self.startSpotifyMonitor()
        }

        self.installOverlayCallbacks()
        self.installLauncherCallbacks()
    }

    /// Clipboard monitoring, ingest, and background maintenance — everything
    /// that touches the real pasteboard or the on-disk database.
    private func startCapturePipeline() {
        self.monitor.excludedBundleIDs = { Preferences.currentExclusions() }
        self.monitor.start()

        let store = store
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
                            await AppServices.enrich(item: item, snapshot: snapshot, store: store)
                        }
                    }
                } catch {
                    logger.error("ingest failed: \(String(describing: error), privacy: .public)")
                }
            }
        }

        // Trim history (and orphaned blobs) on launch and hourly thereafter.
        self.purgeTask = Task(priority: .background) { [logger] in
            while !Task.isCancelled {
                let limit = Defaults[.historyLimit]
                do {
                    try await store.purge(keepingLatest: max(limit, 100))
                } catch {
                    logger.error("purge failed: \(String(describing: error), privacy: .public)")
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }

        // Reclaim orphaned blob files and compact the DB on launch, then daily.
        self.maintenanceTask = Task(priority: .background) { [logger] in
            // Let launch settle before the first (VACUUM-heavy) pass.
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
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
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }

        // Backfill rich-link metadata for existing links, once per launch.
        // Runs 60s after launch (let capture/OCR settle first), then drains the
        // queue in small batches with a pause between fetches to stay a polite
        // network citizen. Stops when no links remain; picks up again next launch.
        self.linkBackfillTask = Task(priority: .background) { [logger] in
            try? await Task.sleep(for: .seconds(60))
            guard Defaults[.richLinkPreviews] else { return }
            while !Task.isCancelled {
                let links: [ClipItem]
                do {
                    links = try await store.linksNeedingMetadata(limit: 25)
                } catch {
                    logger.error("link backfill query failed: \(String(describing: error), privacy: .public)")
                    return
                }
                guard !links.isEmpty else { return }
                for link in links {
                    if Task.isCancelled { return }
                    await Self.fetchLinkMetadata(for: link, store: store)
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }

        // Detected secrets expire on a short leash, swept every minute.
        self.secretSweepTask = Task(priority: .background) {
            while !Task.isCancelled {
                let ttlMinutes = Defaults[.secretTTLMinutes]
                if ttlMinutes > 0 {
                    let cutoff = Date().addingTimeInterval(-Double(ttlMinutes) * 60)
                    try? await store.purgeExpiredSecrets(olderThan: cutoff)
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Spotify now-playing: observe playback broadcasts, refresh an open panel
    /// on change, and reconcile a fresh snapshot each time the launcher opens.
    private func startSpotifyMonitor() {
        self.spotify.onChange = { [weak self] in
            guard let self, self.launcher.isVisible else { return }
            self.launcher.refreshRows()
        }
        self.launcher.onWillShow = { [weak self] in
            self?.spotify.refreshSnapshot()
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
                guard #available(macOS 26.0, *) else { return }
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
        self.launcher.onCopyText = { [weak self] text in
            self?.copyString(text, hud: "Result copied — ⌘V to paste")
        }
        self.launcher.onPasteText = { [weak self] text, target in
            self?.pasteString(text, into: target)
        }
        self.launcher.onOpenFile = { url in
            NSWorkspace.shared.open(url)
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
            self?.pasteItem(item, mode: mode, into: target)
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
            // `:stats` has no action of its own — ↩ opens Settings, where the
            // full library breakdown lives (the row subtitle is the summary).
            // Settings has no tab-selection binding today, so this opens the
            // default (General) tab rather than History specifically.
            case .version, .stats, .settings: Self.openSettings()
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
    static func openSettings() {
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
        alert.messageText = "Clear all clipboard history?"
        alert.informativeText = "Pinned items are kept."
        alert.addButton(withTitle: "Clear")
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

    /// One-line library summary for the `:stats` row, e.g.
    /// "1,234 items · 812 text · 96 links · 12 images". Shows the top kinds from
    /// `byKind` (already most-frequent first); no byte total.
    /// `nonisolated` so the launcher's off-main `dynamicSubtitle` closure can
    /// call it — it's pure.
    private nonisolated static func statsSubtitle(_ stats: LibraryStats) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        func number(_ value: Int) -> String {
            formatter.string(from: NSNumber(value: value)) ?? String(value)
        }
        let itemWord = stats.total == 1 ? "item" : "items"
        var parts = ["\(number(stats.total)) \(itemWord)"]
        for kindCount in stats.byKind.prefix(3) {
            parts.append("\(number(kindCount.count)) \(Self.kindLabel(kindCount.kind, count: kindCount.count))")
        }
        return parts.joined(separator: " · ")
    }

    /// Human, pluralized name for a kind in the stats summary ("text", "links").
    private nonisolated static func kindLabel(_ kind: ItemKind, count: Int) -> String {
        switch kind {
        case .text: "text"
        case .link: count == 1 ? "link" : "links"
        case .image: count == 1 ? "image" : "images"
        case .file: count == 1 ? "file" : "files"
        case .color: count == 1 ? "color" : "colors"
        }
    }

    private func registerHotkeys() {
        HotkeyService.onToggleDrawer { [weak self] in
            self?.overlay.toggle()
        }

        HotkeyService.onToggleLauncher { [weak self] in
            self?.launcher.toggle()
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
    nonisolated static func applyingAutoTransforms(to snapshot: PasteboardSnapshot) -> PasteboardSnapshot {
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

    /// Post-ingest enrichment: OCR for images (always), then LLM title +
    /// category (macOS 26 + Apple Intelligence + setting enabled). Runs off
    /// the ingest loop; every step is best-effort.
    /// nonisolated: OCR is sync CPU work and must not land on the main actor.
    private nonisolated static func enrich(item: ClipItem, snapshot: PasteboardSnapshot, store: ClipStore) async {
        // Only fresh, non-secret items; bumped duplicates are already enriched.
        guard item.useCount == 1, !item.isSecret else { return }

        var textForLabeling: String?

        if item.kind == .image,
           let png = snapshot.reps.first(where: { $0.uti == WellKnownUTI.png })?.data
        {
            // Attach even empty results so textless images are marked as
            // OCR-attempted (searchText '' vs NULL).
            let recognized = ImageTextRecognizer.recognizeText(in: png) ?? ""
            try? await store.attachRecognizedText(itemID: item.id, text: recognized)
            textForLabeling = recognized.isEmpty ? nil : recognized
        } else if item.kind == .text {
            textForLabeling = snapshot.reps
                .first { $0.uti == WellKnownUTI.plainText }
                .flatMap { String(data: $0.data, encoding: .utf8) }
        } else if item.kind == .link, Defaults[.richLinkPreviews] {
            await Self.fetchLinkMetadata(for: item, store: store)
        }

        guard Defaults[.aiFeatures],
              ClipEnricher.isAvailable,
              let text = textForLabeling,
              text.count >= 80
        else { return }

        if #available(macOS 26.0, *) {
            guard let enrichment = try? await ClipEnricher.enrich(text: text) else { return }
            // Short clips show fully on the card; a summary only earns its
            // space once the preview truncates.
            let summary = text.count >= ClipEnricher.summaryWorthwhileLength
                ? enrichment.summary : nil
            try? await store.attachEnrichment(
                itemID: item.id,
                title: enrichment.title,
                category: enrichment.category,
                summary: summary
            )
        }
    }

    /// Fetches rich-link metadata for one `.link` item and attaches it (or the
    /// empty-title sentinel on failure, so it's marked attempted and won't be
    /// retried by backfill). Guards on fetchability; nil-URL / unfetchable links
    /// still get the sentinel. Shared by post-ingest enrichment and backfill.
    private nonisolated static func fetchLinkMetadata(for item: ClipItem, store: ClipStore) async {
        guard let preview = item.previewText,
              let url = URL(string: preview.trimmingCharacters(in: .whitespacesAndNewlines)),
              LinkMetadataFetcher.isFetchable(url)
        else {
            // Not fetchable → record the sentinel so we don't re-check every pass.
            try? await store.attachLinkMetadata(
                itemID: item.id, title: "", description: nil, faviconPNG: nil, previewImagePNG: nil
            )
            return
        }
        let metadata = await LinkMetadataFetcher().fetch(url)
        try? await store.attachLinkMetadata(
            itemID: item.id,
            title: metadata?.title ?? "",
            description: metadata?.description,
            faviconPNG: metadata?.faviconPNG,
            previewImagePNG: metadata?.previewImagePNG
        )
    }

    /// Prefetches payloads, runs the pure action, then executes its effect.
    private func runAction(_ action: ClipAction, on items: [ClipItem], target: NSRunningApplication?) async {
        var inputs: [ActionInput] = []
        for item in items {
            let text = try? await self.store.plainText(for: item.id)
            var fileURLs: [URL] = []
            if item.kind == .file,
               let rep = try? await self.store.representations(for: item.id)
               .first(where: { $0.uti == WellKnownUTI.fileURLs }),
               let data = try? await self.store.payload(for: rep),
               let strings = try? JSONDecoder().decode([String].self, from: data)
            {
                fileURLs = strings.compactMap(URL.init(string:))
            }
            inputs.append(ActionInput(item: item, plainText: text, fileURLs: fileURLs))
        }

        switch action.run(inputs) {
        case let .pasteText(text):
            self.pasteString(text, into: target)

        case let .copyText(text, hud):
            self.copyString(text, hud: hud)

        case let .openURLs(urls):
            for url in urls {
                NSWorkspace.shared.open(url)
            }

        case let .revealFiles(urls):
            NSWorkspace.shared.activateFileViewerSelecting(urls)

        case let .saveImage(itemID):
            await self.saveImageToDownloads(itemID: itemID)

        case let .openImage(itemID):
            await self.openImageInPreview(itemID: itemID)

        case let .addToStack(items):
            for item in items {
                self.stack.push(item)
            }
            HUDController.shared.flash("\(items.count) items on the stack — ⌥⌘V to paste")

        case let .showMessage(message):
            HUDController.shared.flash(message)
        }
    }

    private func openImageInPreview(itemID: String) async {
        guard let rep = try? await self.store.representations(for: itemID)
            .first(where: { $0.uti == WellKnownUTI.png }),
            let data = try? await self.store.payload(for: rep)
        else {
            HUDController.shared.flash("Couldn't open image")
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Overboard-\(itemID).png")
        do {
            try data.write(to: url)
        } catch {
            HUDController.shared.flash("Couldn't open image")
            return
        }
        // Force Preview.app to match the action's label, falling back to the
        // system default PNG handler if it's somehow missing.
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            do {
                _ = try await NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: preview,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            } catch {
                NSWorkspace.shared.open(url)
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func saveImageToDownloads(itemID: String) async {
        guard let rep = try? await self.store.representations(for: itemID)
            .first(where: { $0.uti == WellKnownUTI.png }),
            let data = try? await self.store.payload(for: rep),
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        else {
            HUDController.shared.flash("Couldn't save image")
            return
        }
        let stamp = Date().formatted(.iso8601.year().month().day().timeSeparator(.omitted).time(includingFractionalSeconds: false))
        let url = downloads.appendingPathComponent("Overboard \(stamp).png")
        do {
            try data.write(to: url)
            HUDController.shared.flash("Saved to Downloads")
        } catch {
            HUDController.shared.flash("Couldn't save image")
        }
    }

    /// Writes to the pasteboard with the monitor's marker type so the copy
    /// doesn't re-enter history, then flashes the HUD.
    private func copyString(_ text: String, hud: String) {
        let pbItem = NSPasteboardItem()
        pbItem.setString(text, forType: .string)
        pbItem.setData(Data(), forType: ClipboardMonitor.markerType)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([pbItem])
        HUDController.shared.flash(hud)
    }

    private func pasteString(_ text: String, into target: NSRunningApplication?) {
        let restore = Defaults[.restoreClipboard]
        let outcome = self.pasteback.pasteText(text, into: target, restoreClipboard: restore)
        if outcome == .copiedOnly {
            HUDController.shared.flash("Copied — press ⌘V to paste")
            PermissionService.promptIfNeeded()
        }
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
                    HUDController.shared.flash("Copied — press ⌘V to paste")
                    PermissionService.promptIfNeeded()
                }
            } catch {
                self.logger.error("paste failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
