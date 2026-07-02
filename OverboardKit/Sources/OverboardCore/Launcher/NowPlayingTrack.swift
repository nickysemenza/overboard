import Foundation

/// The track Spotify is currently playing (or has paused). Built from the
/// `com.spotify.client.PlaybackStateChanged` distributed notification or from
/// an AppleScript snapshot; both funnel through the pure parsers below so the
/// parsing is testable without a running Spotify.
public struct NowPlayingTrack: Sendable, Equatable {
    public enum PlayerState: String, Sendable {
        case playing = "Playing"
        case paused = "Paused"
    }

    public var title: String
    public var artist: String
    /// Spotify URI, e.g. "spotify:track:6rqhFgbbKwnb9MLmUQDhG6".
    public var trackID: String
    public var state: PlayerState

    public init(title: String, artist: String, trackID: String, state: PlayerState) {
        self.title = title
        self.artist = artist
        self.trackID = trackID
        self.state = state
    }

    /// spotify:track:X → https://open.spotify.com/track/X (also episode/show).
    /// nil for local files ("spotify:local:…"), ads, and malformed URIs — the
    /// caller falls back to copying "Title — Artist" text instead.
    public var shareURL: URL? {
        let parts = self.trackID.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              parts[0] == "spotify",
              ["track", "episode", "show"].contains(parts[1]),
              !parts[2].isEmpty
        else { return nil }
        return URL(string: "https://open.spotify.com/\(parts[1])/\(parts[2])")
    }

    /// Parses the userInfo of "com.spotify.client.PlaybackStateChanged".
    /// Keys: "Name", "Artist", "Track ID", "Player State"
    /// (Playing/Paused/Stopped). Returns nil for "Stopped" or missing keys.
    public static func parse(playbackNotification userInfo: [AnyHashable: Any]) -> NowPlayingTrack? {
        guard let stateRaw = userInfo["Player State"] as? String,
              let state = PlayerState(rawValue: stateRaw),
              let title = userInfo["Name"] as? String, !title.isEmpty,
              let trackID = userInfo["Track ID"] as? String, !trackID.isEmpty
        else { return nil }
        let artist = userInfo["Artist"] as? String ?? ""
        return NowPlayingTrack(title: title, artist: artist, trackID: trackID, state: state)
    }

    /// Parses the tab-separated snapshot line our AppleScript emits
    /// ("Playing\tName\tArtist\tspotify:track:X"). Returns nil for the empty
    /// string (Spotify stopped) or malformed input.
    public static func parse(snapshotLine: String) -> NowPlayingTrack? {
        let fields = snapshotLine.components(separatedBy: "\t")
        guard fields.count == 4 else { return nil }
        // Spotify reports "playing"/"paused"; normalize the leading capital.
        let stateRaw = fields[0].prefix(1).uppercased() + fields[0].dropFirst().lowercased()
        guard let state = PlayerState(rawValue: stateRaw),
              !fields[1].isEmpty,
              !fields[3].isEmpty
        else { return nil }
        return NowPlayingTrack(title: fields[1], artist: fields[2], trackID: fields[3], state: state)
    }
}
