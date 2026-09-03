import Foundation
import Combine
import AppKit

enum NowPlayingTheme: String, CaseIterable, Identifiable {
    case dark
    case twitchPurple = "twitch-purple"
    case transparent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dark: return "Dark"
        case .twitchPurple: return "Twitch Purple"
        case .transparent: return "Transparente"
        }
    }
}

/// Drives the "Now Playing" overlay — reads the track currently playing in
/// Music.app (via `MusicPoller`) and serves it (plus, optionally, its real
/// audio) to an OBS Browser Source through its own local HTTP server
/// (`NowPlayingHTTPServer`, its own port — see that type's doc comment for
/// why it isn't folded into the printer overlay's `LocalHTTPServer`).
/// Independent of `AppState` (the printer/MQTT side) by design: this is a
/// separate feature bolted onto the same menu-bar app, not a shared pipeline.
@MainActor
final class NowPlayingState: ObservableObject {
    @Published var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: Keys.port) }
    }
    @Published var theme: NowPlayingTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Keys.theme) }
    }
    @Published private(set) var isServerRunning = false
    @Published private(set) var nowPlaying: NowPlayingInfo = .idle
    @Published var lastError: String?

    // MARK: Audio routing ("streaming only" toggle)
    @Published private(set) var isStreamingOnlyEnabled = false
    @Published private(set) var isAudioRoutingBusy = false
    /// Backing storage for the (macOS 14.2+-only) capture engine, boxed as
    /// `Any` so this property can exist on a class that itself must keep
    /// supporting older macOS — see `audioCapture` below.
    private var audioCaptureBox: Any?

    private let server = NowPlayingHTTPServer()
    private let poller = MusicPoller()

    private enum Keys {
        static let port = "nowPlayingPort"
        static let theme = "nowPlayingTheme"
    }

    init() {
        let savedPort = UserDefaults.standard.integer(forKey: Keys.port)
        self.port = savedPort == 0 ? 8080 : savedPort
        let savedTheme = UserDefaults.standard.string(forKey: Keys.theme).flatMap(NowPlayingTheme.init(rawValue:))
        self.theme = savedTheme ?? .dark

        server.snapshotProvider = { [poller] in poller.latest }
        server.artworkURLProvider = { [poller] in
            FileManager.default.fileExists(atPath: poller.artworkFileURL.path) ? poller.artworkFileURL : nil
        }
        poller.onUpdate = { [weak self] info in
            self?.updateNowPlayingIfNeeded(info)
        }

        poller.start()
        startServer()
    }

    /// The menu bar UI only ever displays title/artist/album/play-state — never
    /// live position — so we must NOT republish on every 1s poll tick just
    /// because `positionMs`/`serverTimeMs` ticked forward. The HTTP overlay
    /// reads position straight from the poller (see `snapshotProvider` above),
    /// completely bypassing this `@Published` property, so skipping those
    /// updates here costs the overlay nothing.
    ///
    /// Publishing unconditionally here previously meant SwiftUI's observation
    /// tracking re-ran forever, once a second, for as long as the app was
    /// open — since `MenuBarExtra`'s `label` stays mounted (and subscribed)
    /// even while the menu is closed, that turned into an unbounded, ever
    /// re-triggering render loop that pegged a CPU core continuously the
    /// longer the app stayed running.
    private func updateNowPlayingIfNeeded(_ info: NowPlayingInfo) {
        let current = nowPlaying
        let displayRelevantChange =
            current.trackId != info.trackId ||
            current.isPlaying != info.isPlaying ||
            current.playbackState != info.playbackState ||
            current.title != info.title ||
            current.artist != info.artist ||
            current.album != info.album
        guard displayRelevantChange else { return }
        nowPlaying = info
    }

    // MARK: - Audio routing ("Music só no streaming")

    /// True when this Mac can use the audio-routing toggle at all (macOS
    /// 14.2+, needed for the local-mute half of the feature). The menu
    /// hides/disables the toggle when this is false.
    var isAudioCaptureSupported: Bool {
        if #available(macOS 14.2, *) { return true } else { return false }
    }

    @available(macOS 14.2, *)
    private var audioCapture: AudioCaptureEngine {
        if let existing = audioCaptureBox as? AudioCaptureEngine { return existing }
        let engine = AudioCaptureEngine()
        audioCaptureBox = engine
        return engine
    }

    /// Turns "Music só no streaming" on or off.
    ///
    /// On: silences Music.app on the user's own speakers/headset (a Core
    /// Audio process tap on Music.app, muted) while capturing its real audio
    /// via ScreenCaptureKit's per-app audio capture (same class of API OBS's
    /// own "Application Audio Capture" source uses) and broadcasting it over
    /// `/audio-stream` for the overlay page to play. Everything else on the
    /// Mac (a game, system sounds, any other app) is completely unaffected,
    /// since nothing about output ROUTING is touched.
    ///
    /// Off: stops both. Music.app's audio reaches its normal output again
    /// immediately.
    func setStreamingOnly(_ enabled: Bool) {
        guard !isAudioRoutingBusy else { return }
        guard #available(macOS 14.2, *) else {
            lastError = "Esse recurso requer macOS 14.2 ou mais recente."
            return
        }

        if enabled {
            isAudioRoutingBusy = true
            let capture = audioCapture
            let server = server
            capture.onPCMChunk = { [weak server] data in
                server?.broadcastAudio(data)
            }
            capture.start { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.isAudioRoutingBusy = false
                    switch result {
                    case .success:
                        self.isStreamingOnlyEnabled = true
                        self.lastError = nil
                    case .failure(let error):
                        self.isStreamingOnlyEnabled = false
                        self.lastError = error.description
                    }
                }
            }
        } else {
            isAudioRoutingBusy = true
            audioCapture.stop()
            isStreamingOnlyEnabled = false
            isAudioRoutingBusy = false
            lastError = nil
        }
    }

    func startServer() {
        guard !isServerRunning else { return }
        guard let portValue = UInt16(exactly: port) else {
            lastError = "Porta inválida."
            return
        }
        server.start(port: portValue) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    self.isServerRunning = true
                    self.lastError = nil
                case .failure(let error):
                    self.isServerRunning = false
                    self.lastError = error.description
                }
            }
        }
    }

    func stopServer() {
        server.stop()
        isServerRunning = false
    }

    func restartServer() {
        stopServer()
        startServer()
    }

    var obsURL: String {
        "http://127.0.0.1:\(port)/overlay.html?theme=\(theme.rawValue)"
    }

    func copyOBSURLToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(obsURL, forType: .string)
    }
}
