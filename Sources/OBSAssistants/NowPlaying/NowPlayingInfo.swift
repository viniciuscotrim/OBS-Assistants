import Foundation

/// Playback state as reported by Music.app.
enum PlaybackState: String, Codable {
    case playing
    case paused
    case stopped
}

/// Snapshot of the currently playing track, serialized to JSON for the
/// `/nowplaying` HTTP endpoint.
struct NowPlayingInfo: Codable, Equatable {
    var title: String
    var artist: String
    var album: String
    var positionMs: Int
    var durationMs: Int
    var isPlaying: Bool
    var playbackState: String
    var artworkUrl: String?
    /// Monotonically increasing identifier used by clients to detect a track change
    /// (title+artist+album can collide across duplicate library entries; this doesn't).
    var trackId: String
    /// Server-side timestamp (ms since epoch) at which this snapshot was captured.
    /// Clients use this to interpolate `positionMs` smoothly between polls.
    var serverTimeMs: Int

    static let idle = NowPlayingInfo(
        title: "",
        artist: "",
        album: "",
        positionMs: 0,
        durationMs: 0,
        isPlaying: false,
        playbackState: PlaybackState.stopped.rawValue,
        artworkUrl: nil,
        trackId: "none",
        serverTimeMs: Int(Date().timeIntervalSince1970 * 1000)
    )
}
