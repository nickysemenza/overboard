import AppKit
import os
import OverboardCore
import OverboardMac
import OverboardUI

/// Composition root: owns the store, monitor, overlay, hotkey, and paste-back.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let store: ClipStore
    let monitor: ClipboardMonitor
    let pasteback: PastebackService
    let overlay: OverlayController
    let stack = PasteStack()

    private var ingestTask: Task<Void, Never>?
    private var purgeTask: Task<Void, Never>?
    private var secretSweepTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.nicky.overboard", category: "app")

    private init() {
        do {
            let directory = try OverboardDatabase.defaultDirectory()
            let pool = try OverboardDatabase.open(at: directory)
            let blobs = try BlobStore(directory: directory.appendingPathComponent("blobs", isDirectory: true))
            self.store = ClipStore(dbWriter: pool, blobs: blobs)
        } catch {
            // Without a database there is no app; surface loudly in dev.
            fatalError("Failed to open Overboard database: \(error)")
        }
        self.monitor = ClipboardMonitor()
        self.pasteback = PastebackService(store: self.store)
        self.overlay = OverlayController(store: self.store, stack: self.stack)
    }

    func start() {
        UserDefaults.standard.register(defaults: SettingsKeys.defaults)
        self.monitor.excludedBundleIDs = { SettingsKeys.currentExclusions() }
        self.monitor.start()

        let store = store
        let snapshots = self.monitor.snapshots
        self.ingestTask = Task(priority: .utility) { [logger] in
            for await snapshot in snapshots {
                do {
                    if let item = try await store.ingest(snapshot) {
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
                let limit = UserDefaults.standard.integer(forKey: SettingsKeys.historyLimit)
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
                let ttlMinutes = UserDefaults.standard.integer(forKey: SettingsKeys.secretTTLMinutes)
                if ttlMinutes > 0 {
                    let cutoff = Date().addingTimeInterval(-Double(ttlMinutes) * 60)
                    try? await store.purgeExpiredSecrets(olderThan: cutoff)
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }

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

        HotkeyService.onToggleDrawer { [weak self] in
            self?.overlay.toggle()
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

        guard UserDefaults.standard.bool(forKey: SettingsKeys.aiFeatures),
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

    private func pasteString(_ text: String, into target: NSRunningApplication?) {
        let restore = UserDefaults.standard.bool(forKey: SettingsKeys.restoreClipboard)
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
                   SettingsKeys.currentPlainTextApps().contains(bundleID)
                {
                    effectiveMode = .plainText
                }
                let restore = UserDefaults.standard.bool(forKey: SettingsKeys.restoreClipboard)
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
