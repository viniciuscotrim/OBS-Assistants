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
    /// Raw fact about the track itself — Apple Music streaming/subscription
    /// content, or an older (pre-2009) FairPlay-protected purchase — see
    /// MusicPoller.statusScript's doc comment for how this is detected.
    /// Independent of whether DRM protection is actually turned on.
    var hasDRM: Bool
    /// The overlay's actual current state: `hasDRM` AND the "Silenciar
    /// automaticamente músicas com DRM no stream" toggle is on. This is
    /// what overlay.js shows the "áudio silenciado" banner from — computed
    /// server-side so the client never needs to know about the toggle
    /// itself, just this one flag.
    var drmAudioSilenced: Bool

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
        serverTimeMs: Int(Date().timeIntervalSince1970 * 1000),
        hasDRM: false,
        drmAudioSilenced: false
    )
}
