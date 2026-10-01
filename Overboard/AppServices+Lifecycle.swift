import AppKit
import OverboardMac
import OverboardUI

extension AppServices {
    func reconcileEnabledSources() {
        guard self.isStarted, !Self.isDemo, self.libraryRecovery == nil else { return }
        if Defaults[.launcherFileResults] {
            FileIndexService.shared.start()
        } else {
            FileIndexService.shared.stop()
        }
        if Defaults[.launcherNowPlaying] {
            self.startSpotifyMonitor()
        } else {
            self.spotify.stop()
        }
        if Defaults[.launcherCalendarEvents], CalendarSource.authorization == .granted {
            self.startCalendarSource()
        } else {
            self.calendar.stop()
        }
        if self.launcher.isVisible {
            self.launcherViewModel.scheduleSearch(preserveSelection: true)
        }
    }

    func observeSourcePreferences() {
        self.archivePreferencesObserver = NotificationCenter.default.addObserver(
            forName: ArchivePreferencesAdapter.didApplyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isStarted else { return }
                self.reconcileEnabledSources()
                self.applyFileSearchConfiguration(FileSearchConfiguration(
                    roots: Defaults[.fileSearchRoots], exclusions: Defaults[.fileSearchExclusions]
                ))
            }
        }
        let updates = Defaults.updates([
            Defaults.Keys.launcherFileResults,
            Defaults.Keys.launcherNowPlaying,
            Defaults.Keys.launcherCalendarEvents,
        ], initial: false)
        self.preferenceTask = Task { [weak self] in
            for await _ in updates {
                guard !Task.isCancelled, let self else { return }
                self.reconcileEnabledSources()
            }
        }
    }

    func applyFileSearchConfiguration(_: FileSearchConfiguration) {
        guard self.isStarted, self.libraryRecovery == nil, !Self.isDemo else { return }
        if Defaults[.launcherFileResults] {
            FileIndexService.shared.rebuild()
        } else {
            FileIndexService.shared.stop()
        }
    }
}
