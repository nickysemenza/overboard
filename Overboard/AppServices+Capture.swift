import AppKit
import os
import OverboardCore
import OverboardMac
import OverboardUI

/// Clipboard monitoring, ingest, background maintenance, Spotify now-playing,
/// and capture pause/resume — everything that touches the real pasteboard or
/// the on-disk database.
extension AppServices {
    func startCapturePipeline() {
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
    nonisolated static func maintenanceJobs(
        store: ClipStore,
        enrichment: ClipEnrichmentPipeline,
        logger: Logger
    ) -> [MaintenanceJob] {
        [
            self.purgeJob(store: store, logger: logger),
            self.maintenanceSweepJob(store: store, logger: logger),
            self.linkBackfillJob(store: store, enrichment: enrichment, logger: logger),
            self.secretSweepJob(store: store),
        ]
    }

    /// Trim history (and orphaned blobs) on launch and hourly thereafter.
    private nonisolated static func purgeJob(store: ClipStore, logger: Logger) -> MaintenanceJob {
        MaintenanceJob(name: "purge", interval: .seconds(3600)) {
            let limit = Defaults[.historyLimit]
            do {
                try await store.purge(keepingLatest: max(limit, 100))
            } catch {
                logger.error("purge failed: \(String(describing: error), privacy: .public)")
            }
            return .repeatLater
        }
    }

    /// Reclaim orphaned blob files and compact the DB on launch, then
    /// daily — after letting launch settle, since the first pass is
    /// VACUUM-heavy.
    private nonisolated static func maintenanceSweepJob(store: ClipStore, logger: Logger) -> MaintenanceJob {
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
        }
    }

    /// Backfill rich-link metadata for existing links, once per launch.
    /// Starts 60s after launch (let capture/OCR settle first), then drains
    /// the queue in small batches with a pause between fetches to stay a
    /// polite network citizen. Stops when no links remain; picks up again
    /// next launch.
    private nonisolated static func linkBackfillJob(
        store: ClipStore,
        enrichment: ClipEnrichmentPipeline,
        logger: Logger
    ) -> MaintenanceJob {
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
                if Task.isCancelled {
                    return .finished
                }
                await enrichment.fetchLinkMetadata(for: link)
                try? await Task.sleep(for: .seconds(1))
            }
            return .repeatLater
        }
    }

    /// Detected secrets expire on a short leash, swept every minute.
    private nonisolated static func secretSweepJob(store: ClipStore) -> MaintenanceJob {
        MaintenanceJob(name: "secret sweep", interval: .seconds(60)) {
            let ttlMinutes = Defaults[.secretTTLMinutes]
            if ttlMinutes > 0 {
                let cutoff = Date().addingTimeInterval(-Double(ttlMinutes) * 60)
                try? await store.purgeExpiredSecrets(olderThan: cutoff)
            }
            return .repeatLater
        }
    }

    /// Spotify now-playing: observe playback broadcasts, refresh an open panel
    /// on change, and reconcile a fresh snapshot each time the launcher opens.
    func startSpotifyMonitor() {
        self.spotify.onChange = { [weak self] in
            guard let self, self.launcher.isVisible else { return }
            self.launcher.refreshRows()
        }
        self.spotify.start()
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
    func confirmAndClearHistory() {
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
}
