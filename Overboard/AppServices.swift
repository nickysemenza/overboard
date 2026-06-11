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

    let store: ClipStore
    let monitor: ClipboardMonitor
    let pasteback: PastebackService
    let overlay: OverlayController
    let launcher: LauncherPanelController
    let stack = PasteStack()

    private var ingestTask: Task<Void, Never>?
    private var purgeTask: Task<Void, Never>?
    private var secretSweepTask: Task<Void, Never>?
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
        self.launcher = LauncherPanelController(
            store: self.store,
            viewModel: LauncherViewModel(
                instantProviders: [
                    AppSearchProvider(index: AppIndex(), limit: 5) {
                        AppMatcher.parseAliases(Defaults[.launcherAppAliases])
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
                ]
            )
        )
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
