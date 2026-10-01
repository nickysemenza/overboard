import AppKit
import Foundation
import OverboardCore

/// Tracks Spotify's currently-playing song for the launcher's now-playing row.
///
/// Two data sources, no continuous polling:
///   - a `DistributedNotificationCenter` observer for Spotify's own
///     `PlaybackStateChanged` broadcast (event-driven, permissionless);
///   - an AppleScript `refreshSnapshot()` reconcile, run at launch and on every
///     launcher summon, that recovers the state after a restart or a dropped
///     notification.
public final class SpotifyNowPlayingMonitor {
    public nonisolated static let spotifyBundleID = "com.spotify.client"
    private static let playbackNotification = "com.spotify.client.PlaybackStateChanged"

    public private(set) var current: NowPlayingTrack?
    /// Fired on every state change so a visible launcher can refresh its rows.
    public var onChange: () -> Void = {}

    private var playbackObserver: NSObjectProtocol?
    private var generation = 0
    public private(set) var isRunning = false
    private var terminateObserver: NSObjectProtocol?
    /// Debounces snapshots so rapid launcher reopens don't stack Apple Events.
    private var lastSnapshotAt: Date?
    private let applicationIsRunning: () -> Bool
    private let readSnapshot: @Sendable () async -> String?
    private let now: () -> Date
    private(set) var snapshotTask: Task<Void, Never>?
    /// Concurrent so a wedged Spotify Apple Event can't block later snapshots
    /// for the process lifetime; each job runs an independent NSAppleScript and
    /// hops back to the main actor to apply. See BrowserProvenanceService.
    private nonisolated static let snapshotQueue = DispatchQueue(
        label: "com.nickysemenza.overboard.spotify-snapshot",
        attributes: .concurrent
    )
    /// Caps concurrent snapshots so wedged Apple Events can't accumulate worker
    /// threads; a stuck script holds its slot and further snapshots skip. Static
    /// so the queue block can signal it without capturing the main-actor self.
    private nonisolated static let snapshotSlots = DispatchSemaphore(value: 2)

    public convenience init() {
        self.init(
            applicationIsRunning: {
                !NSRunningApplication.runningApplications(withBundleIdentifier: Self.spotifyBundleID).isEmpty
            },
            readSnapshot: Self.readSnapshot
        )
    }

    init(
        applicationIsRunning: @escaping () -> Bool,
        readSnapshot: @escaping @Sendable () async -> String?,
        now: @escaping () -> Date = Date.init
    ) {
        self.applicationIsRunning = applicationIsRunning
        self.readSnapshot = readSnapshot
        self.now = now
    }

    public func start() {
        guard !self.isRunning else { return }
        self.isRunning = true
        self.generation += 1
        self.lastSnapshotAt = nil
        // Passive: receiving distributed notifications needs no permission and
        // no running-app guard, which also keeps the headless fake-notification
        // test path working without Spotify installed.
        self.playbackObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init(Self.playbackNotification),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Parse to a Sendable value before crossing the isolation boundary;
            // Notification itself isn't Sendable.
            let track = NowPlayingTrack.parse(playbackNotification: notification.userInfo ?? [:])
            MainActor.assumeIsolated {
                self?.receivedPlayback(track)
            }
        }

        // Spotify's own "Stopped" notification can be missed on quit; clear the
        // row deterministically when the app terminates.
        self.terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let isSpotify = app?.bundleIdentifier == Self.spotifyBundleID
            MainActor.assumeIsolated {
                guard isSpotify else { return }
                self?.applicationTerminated()
            }
        }

        // Seed the launch state — notifications only fire on the next change.
        self.refreshSnapshot()
    }

    public func stop() {
        self.isRunning = false
        self.generation += 1
        self.snapshotTask?.cancel()
        self.lastSnapshotAt = nil
        if let playbackObserver {
            DistributedNotificationCenter.default().removeObserver(playbackObserver)
        }
        if let terminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminateObserver)
        }
        self.playbackObserver = nil
        self.terminateObserver = nil
        self.apply(nil)
    }

    /// AppleScript snapshot of Spotify's current track — the reconcile backstop
    /// for missed notifications, run at launch and on every launcher summon.
    /// No-ops when a snapshot ran within the last second; clears the row when
    /// Spotify isn't running (sending Apple Events would relaunch it).
    public func refreshSnapshot() {
        guard self.isRunning else { return }
        guard self.applicationIsRunning() else {
            self.applicationTerminated()
            return
        }
        let now = self.now()
        if let last = lastSnapshotAt, now.timeIntervalSince(last) < 1 {
            return
        }
        self.lastSnapshotAt = now
        self.generation += 1
        self.snapshotTask?.cancel()
        let generation = self.generation
        let readSnapshot = self.readSnapshot

        self.snapshotTask = Task { [weak self] in
            let line = await readSnapshot()
            guard let self, !Task.isCancelled, self.isRunning, self.generation == generation else { return }
            guard self.applicationIsRunning() else {
                self.applicationTerminated()
                return
            }
            if line?.isEmpty == true {
                self.apply(nil)
            } else if let line, let track = NowPlayingTrack.parse(snapshotLine: line) {
                self.apply(track)
            }
        }
    }

    func receivedPlayback(_ track: NowPlayingTrack?) {
        guard self.isRunning else { return }
        self.generation += 1
        self.snapshotTask?.cancel()
        self.apply(track)
    }

    func applicationTerminated() {
        guard self.isRunning else { return }
        self.generation += 1
        self.snapshotTask?.cancel()
        self.lastSnapshotAt = nil
        self.apply(nil)
    }

    private nonisolated static func readSnapshot() async -> String? {
        // Off the main thread so a slow Apple Event (or the one-time Automation
        // TCC prompt) never freezes the launcher summon. Non-blocking slot
        // acquire caps in-flight scripts so wedges can't leak threads.
        guard self.acquireSnapshotSlot() else { return nil }
        return await withCheckedContinuation { continuation in
            self.snapshotQueue.async {
                defer { self.snapshotSlots.signal() }
                continuation.resume(returning: self.runSnapshotScript())
            }
        }
    }

    private nonisolated static func acquireSnapshotSlot() -> Bool {
        self.snapshotSlots.wait(timeout: .now()) == .success
    }

    /// Runs the Spotify snapshot AppleScript. Returns the tab-separated line,
    /// "" when stopped, or nil on error (Automation denied, script failure).
    /// nonisolated: runs on `snapshotQueue`, never on the main actor.
    private nonisolated static func runSnapshotScript() -> String? {
        let source = """
        tell application "Spotify"
            if player state is stopped then return ""
            return (player state as text) & tab & name of current track & tab \
        & artist of current track & tab & id of current track
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if error != nil {
            return nil
        }
        return output.stringValue ?? ""
    }

    private func apply(_ track: NowPlayingTrack?) {
        guard track != self.current else { return }
        self.current = track
        self.onChange()
    }
}
