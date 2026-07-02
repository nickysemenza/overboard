import Foundation
@testable import OverboardCore
import Testing

struct NowPlayingTrackTests {
    // MARK: - Notification parsing

    @Test func parsesPlayingNotification() {
        let track = NowPlayingTrack.parse(playbackNotification: [
            "Name": "Bohemian Rhapsody",
            "Artist": "Queen",
            "Track ID": "spotify:track:6rqhFgbbKwnb9MLmUQDhG6",
            "Player State": "Playing",
        ])
        #expect(track == NowPlayingTrack(
            title: "Bohemian Rhapsody",
            artist: "Queen",
            trackID: "spotify:track:6rqhFgbbKwnb9MLmUQDhG6",
            state: .playing
        ))
    }

    @Test func parsesPausedNotification() {
        let track = NowPlayingTrack.parse(playbackNotification: [
            "Name": "Song",
            "Artist": "Artist",
            "Track ID": "spotify:track:abc",
            "Player State": "Paused",
        ])
        #expect(track?.state == .paused)
    }

    @Test func stoppedNotificationYieldsNil() {
        let track = NowPlayingTrack.parse(playbackNotification: [
            "Name": "Song",
            "Artist": "Artist",
            "Track ID": "spotify:track:abc",
            "Player State": "Stopped",
        ])
        #expect(track == nil)
    }

    @Test func missingKeysYieldNil() {
        #expect(NowPlayingTrack.parse(playbackNotification: [
            "Artist": "Artist", "Track ID": "spotify:track:abc", "Player State": "Playing",
        ]) == nil)
        #expect(NowPlayingTrack.parse(playbackNotification: [
            "Name": "Song", "Artist": "Artist", "Player State": "Playing",
        ]) == nil)
        #expect(NowPlayingTrack.parse(playbackNotification: [
            "Name": "Song", "Artist": "Artist", "Track ID": "spotify:track:abc",
        ]) == nil)
    }

    @Test func emptyNameOrTrackIDYieldsNil() {
        #expect(NowPlayingTrack.parse(playbackNotification: [
            "Name": "", "Artist": "A", "Track ID": "spotify:track:abc", "Player State": "Playing",
        ]) == nil)
        #expect(NowPlayingTrack.parse(playbackNotification: [
            "Name": "Song", "Artist": "A", "Track ID": "", "Player State": "Playing",
        ]) == nil)
    }

    @Test func missingArtistDefaultsToEmpty() {
        let track = NowPlayingTrack.parse(playbackNotification: [
            "Name": "Podcast Episode",
            "Track ID": "spotify:episode:xyz",
            "Player State": "Playing",
        ])
        #expect(track?.artist == "")
    }

    // MARK: - shareURL

    @Test func trackURIBuildsShareURL() {
        let track = NowPlayingTrack(title: "S", artist: "A", trackID: "spotify:track:abc123", state: .playing)
        #expect(track.shareURL == URL(string: "https://open.spotify.com/track/abc123"))
    }

    @Test func episodeURIBuildsShareURL() {
        let track = NowPlayingTrack(title: "S", artist: "A", trackID: "spotify:episode:ep9", state: .playing)
        #expect(track.shareURL == URL(string: "https://open.spotify.com/episode/ep9"))
    }

    @Test func localAndMalformedURIsYieldNilShareURL() {
        // Local files have five components — not a shareable web link.
        #expect(NowPlayingTrack(title: "S", artist: "A", trackID: "spotify:local:a:b:c", state: .playing)
            .shareURL == nil)
        // Empty id.
        #expect(NowPlayingTrack(title: "S", artist: "A", trackID: "spotify:track:", state: .playing)
            .shareURL == nil)
        // Not a whitelisted kind.
        #expect(NowPlayingTrack(title: "S", artist: "A", trackID: "spotify:ad:xyz", state: .playing)
            .shareURL == nil)
        // Garbage.
        #expect(NowPlayingTrack(title: "S", artist: "A", trackID: "", state: .playing)
            .shareURL == nil)
    }

    // MARK: - Snapshot-line parsing

    @Test func parsesSnapshotLine() {
        let track = NowPlayingTrack.parse(snapshotLine: "playing\tImagine\tJohn Lennon\tspotify:track:xyz")
        #expect(track == NowPlayingTrack(
            title: "Imagine", artist: "John Lennon", trackID: "spotify:track:xyz", state: .playing
        ))
    }

    @Test func parsesPausedSnapshotLine() {
        let track = NowPlayingTrack.parse(snapshotLine: "paused\tSong\tArtist\tspotify:track:xyz")
        #expect(track?.state == .paused)
    }

    @Test func emptySnapshotLineYieldsNil() {
        #expect(NowPlayingTrack.parse(snapshotLine: "") == nil)
    }

    @Test func malformedSnapshotLineYieldsNil() {
        #expect(NowPlayingTrack.parse(snapshotLine: "playing\tonly\ttwo") == nil)
        #expect(NowPlayingTrack.parse(snapshotLine: "bogus\tSong\tArtist\tspotify:track:xyz") == nil)
        #expect(NowPlayingTrack.parse(snapshotLine: "playing\t\tArtist\tspotify:track:xyz") == nil)
    }
}
