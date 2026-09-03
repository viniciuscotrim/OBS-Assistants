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

    // MARK: Audio routing — two independent toggles (see AudioCaptureEngine's
    // doc comment for why they're no longer one all-or-nothing switch).
    /// Music.app's audio is being captured and broadcast to the overlay
    /// (`/audio-stream`) for OBS — independent of `isLocalMuted` below, so
    /// this alone lets you hear Music.app normally on your own speakers
    /// *and* have the same audio reach the stream.
    @Published private(set) var isBroadcasting = false
    /// Music.app is also silenced on the Mac's own output. Only meaningful
    /// while `isBroadcasting` is on — the UI disables this toggle otherwise,
    /// and turning broadcasting off force-clears this too (see
    /// `setBroadcasting`), since staying muted with nothing capturing the
    /// audio would just lose the sound entirely.
    @Published private(set) var isLocalMuted = false
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

        // The Music.app poller runs regardless (cheap, local, just keeps the
        // menu's "now playing" status current) — but the HTTP server itself
        // stays off until the user starts it from the menu, same as the
        // other two overlays. See OBSAssistantsApp/AppState for the printer
        // side of this — no overlay server auto-starts anymore.
        poller.start()
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

    /// Turns broadcasting Music.app's audio to the overlay (`/audio-stream`)
    /// on or off — via ScreenCaptureKit's per-app audio capture (same class
    /// of API OBS's own "Application Audio Capture" source uses).
    /// Independent of `setLocalMuted`: on its own, this lets you hear
    /// Music.app normally on your own speakers/headset *while the same
    /// audio also reaches the stream* — enable `setLocalMuted` too for the
    /// original "stream only, silent locally" behavior.
    ///
    /// Turning broadcasting off also force-clears local mute (if it was on)
    /// — there's no point silencing Music.app locally once nothing is
    /// capturing its audio anywhere.
    func setBroadcasting(_ enabled: Bool) {
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
            capture.startCapture { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.isAudioRoutingBusy = false
                    switch result {
                    case .success:
                        self.isBroadcasting = true
                        self.lastError = nil
                    case .failure(let error):
                        self.isBroadcasting = false
                        self.lastError = error.description
                    }
                }
            }
        } else {
            isAudioRoutingBusy = true
            audioCapture.stopCapture()
            isBroadcasting = false
            if isLocalMuted {
                audioCapture.stopMute()
                isLocalMuted = false
            }
            isAudioRoutingBusy = false
            lastError = nil
        }
    }

    /// Also silences Music.app on the Mac's own output (a Core Audio
    /// process tap, muted — its *existence*, wrapped in a running aggregate,
    /// is what actually silences the real output device; see
    /// AudioCaptureEngine's doc comment). Only meaningful while
    /// `isBroadcasting` is on; no-ops otherwise so the audio is never lost
    /// entirely (muted locally with nothing capturing it for the stream).
    func setLocalMuted(_ enabled: Bool) {
        guard !isAudioRoutingBusy else { return }
        guard #available(macOS 14.2, *) else { return }
        guard isBroadcasting || !enabled else { return }

        isAudioRoutingBusy = true
        if enabled {
            do {
                try audioCapture.startMute()
                isLocalMuted = true
                lastError = nil
            } catch {
                isLocalMuted = false
                lastError = (error as? AudioCaptureError)?.description ?? "Falha ao silenciar localmente."
            }
        } else {
            audioCapture.stopMute()
            isLocalMuted = false
        }
        isAudioRoutingBusy = false
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
