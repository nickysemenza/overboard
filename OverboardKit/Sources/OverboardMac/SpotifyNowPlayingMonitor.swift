import AppKit
import Foundation
import os
import OverboardCore

/// Tracks Spotify's currently-playing song for the launcher's now-playing row.
///
/// Two data sources, no continuous polling:
///   - a `DistributedNotificationCenter` observer for Spotify's own
///     `PlaybackStateChanged` broadcast (event-driven, permissionless);
///   - an AppleScript `refreshSnapshot()` reconcile, run at launch and on every
///     launcher summon, that recovers the state after a restart or a dropped
///     notification.
@MainActor
public final class SpotifyNowPlayingMonitor {
    public static let spotifyBundleID = "com.spotify.client"
    private static let playbackNotification = "com.spotify.client.PlaybackStateChanged"

    public private(set) var current: NowPlayingTrack?
    /// Fired on every state change so a visible launcher can refresh its rows.
    public var onChange: () -> Void = {}

    private var playbackObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    /// Debounces snapshots so rapid launcher reopens don't stack Apple Events.
    private var lastSnapshotAt: Date?
    private let snapshotQueue = DispatchQueue(label: "com.nickysemenza.overboard.spotify-snapshot")
    private let logger = Logger(subsystem: "com.nickysemenza.overboard", category: "spotify")

    public init() {}

    public func start() {
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
                self?.apply(track)
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
                self?.apply(nil)
            }
        }

        // Seed the launch state — notifications only fire on the next change.
        self.refreshSnapshot()
    }

    public func stop() {
        if let playbackObserver {
            DistributedNotificationCenter.default().removeObserver(playbackObserver)
        }
        if let terminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminateObserver)
        }
        self.playbackObserver = nil
        self.terminateObserver = nil
    }

    /// AppleScript snapshot of Spotify's current track — the reconcile backstop
    /// for missed notifications, run at launch and on every launcher summon.
    /// No-ops when a snapshot ran within the last second; clears the row when
    /// Spotify isn't running (sending Apple Events would relaunch it).
    public func refreshSnapshot() {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.spotifyBundleID).isEmpty else {
            self.apply(nil)
            return
        }
        if let last = lastSnapshotAt, Date().timeIntervalSince(last) < 1 { return }
        self.lastSnapshotAt = Date()

        // Off the main thread so a slow Apple Event (or the one-time Automation
        // TCC prompt) never freezes the launcher summon.
        self.snapshotQueue.async { [weak self] in
            let line = Self.runSnapshotScript()
            let track = line.flatMap(NowPlayingTrack.parse(snapshotLine:))
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A definitive empty ("") result clears the row; a parsed track
                // sets it. An unparseable non-empty line (ads, errors) is left
                // to the notification path rather than clobbering live state.
                if line?.isEmpty == true {
                    self.apply(nil)
                } else if let track {
                    self.apply(track)
                }
            }
        }
    }

    /// Runs the Spotify snapshot AppleScript. Returns the tab-separated line,
    /// "" when stopped, or nil on error (Automation denied, script failure).
    private static func runSnapshotScript() -> String? {
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
        if error != nil { return nil }
        return output.stringValue ?? ""
    }

    private func apply(_ track: NowPlayingTrack?) {
        guard track != self.current else { return }
        self.current = track
        self.onChange()
    }
}
