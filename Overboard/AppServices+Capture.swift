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
        guard self.libraryRecovery == nil, !self.captureState.isPaused else { return }
        self.enrichmentQueue.start()
        self.monitor.excludedBundleIDs = { Preferences.currentExclusions() }
        self.monitor.start()
        guard self.ingestTask == nil else { return }

        let snapshots = self.monitor.snapshots
        self.ingestTask = Task(priority: .utility) {
            for await snapshot in snapshots {
                guard !Task.isCancelled else { return }
                let task = Task { await self.capture(snapshot) }
                self.activeCaptureTask = task
                await task.value
                self.activeCaptureTask = nil
            }
        }

        self.maintenance.start()
    }

    private func capture(_ original: PasteboardSnapshot) async {
        guard !self.captureState.isPaused else { return }
        let generation = self.captureGeneration
        do {
            try original.admission?.check()
            let snapshot = await Self.applyingLocalProvenance(to: Self.applyingAutoTransforms(to: original))
            guard !Task.isCancelled, self.captureGeneration == generation else { return }
            guard let item = try await self.store.ingest(snapshot),
                  !Task.isCancelled, self.captureGeneration == generation
            else { return }
            self.signal.bump()
            self.enrichmentQueue.enqueue(item: item, snapshot: snapshot)
        } catch is CancellationError {
            return
        } catch {
            self.logger.error("Clipboard ingest failed")
        }
    }

    private static func applyingLocalProvenance(to original: PasteboardSnapshot) async -> PasteboardSnapshot {
        guard let bundleID = original.sourceBundleID,
              BrowserScript.dialect(forBundleID: bundleID) != nil,
              let provenance = await BrowserProvenanceService.fetch(bundleID: bundleID)
        else { return original }
        var snapshot = original
        snapshot.sourceURL = provenance.url
        snapshot.sourceTitle = provenance.title
        return snapshot
    }

    /// The recurring background chores, as data. `MaintenanceScheduler` owns
    /// the cancel-aware loop and the sleeps; each job just does one pass and
    /// says whether it wants another.
    nonisolated static func maintenanceJobs(
        store: ClipStore,
        logger: Logger
    ) -> [MaintenanceJob] {
        [
            self.purgeJob(store: store, logger: logger),
            self.maintenanceSweepJob(store: store, logger: logger),
        ]
    }

    /// Trim history (and orphaned blobs) on launch and hourly thereafter.
    private nonisolated static func purgeJob(store: ClipStore, logger: Logger) -> MaintenanceJob {
        MaintenanceJob(name: "purge", interval: .seconds(3600)) {
            let limit = Defaults[.historyLimit]
            do {
                try await store.purge(keepingLatest: max(limit, 100))
            } catch {
                logger.error("History purge failed")
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
                logger.error("Library maintenance failed")
            }
            return .repeatLater
        }
    }

    /// Spotify now-playing: observe playback broadcasts, refresh an open panel
    /// on change, and reconcile a fresh snapshot each time the launcher opens.
    func startSpotifyMonitor() {
        self.spotify.onChange = { [weak self] in
            guard let self, self.isStarted, self.launcher.isVisible else { return }
            self.launcher.refreshRows()
        }
        self.spotify.start()
    }

    /// Calendar up-next: observe EventKit changes, refresh an open panel on
    /// change, and reconcile a fresh snapshot each time the launcher opens.
    func startCalendarSource() {
        self.calendar.onChange = { [weak self] in
            guard let self, self.isStarted, self.launcher.isVisible else { return }
            self.launcher.refreshRows()
        }
        self.calendar.start()
    }

    /// Applies the user's auto-transform-on-copy rules to a snapshot's
    /// plain-text representation before it's stored, so e.g. tracking params are
    /// stripped from browser URLs at capture. No matching rule returns the
    /// snapshot untouched.
    nonisolated static func applyingAutoTransforms(to snapshot: PasteboardSnapshot) -> PasteboardSnapshot {
        AutoTransform.apply(to: snapshot, rules: Preferences.currentAutoTransformRules())
    }

    // MARK: - Capture pause / resume

    /// Pauses or resumes clipboard capture. Drives both `:pause`/`:resume` and
    /// the menu-bar toggle, and flips `captureState` so the menu-bar icon and
    /// the command list (`:pause` vs `:resume`) stay in sync. No-op in demo
    /// mode, where the monitor is never started.
    func setCapturePaused(_ paused: Bool) {
        guard !Self.isDemo, self.libraryRecovery == nil, self.captureState.isPaused != paused else { return }
        self.captureState.setPaused(paused)
        if paused {
            self.captureGeneration += 1
            self.activeCaptureTask?.cancel()
            self.enrichmentQueue.stop()
            self.monitor.stop()
            HUDController.shared.flash("Clipboard capture paused")
        } else {
            self.startCapturePipeline()
            HUDController.shared.flash("Clipboard capture resumed")
        }
    }

    /// `:clear` — confirm, then purge unpinned, non-sensitive history.
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
                self.logger.error("History clear failed")
                HUDController.shared.flash("Couldn't clear history")
            }
        }
    }
}
