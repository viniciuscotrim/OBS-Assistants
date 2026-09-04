import Foundation
import AppKit

/// Polls Music.app once a second via embedded AppleScript (NSAppleScript, compiled
/// once and re-executed — no per-poll `osascript` process spawn) and publishes a
/// `NowPlayingInfo` snapshot. Album artwork is only re-extracted when the track
/// actually changes, since exporting artwork data is comparatively expensive.
final class MusicPoller {

    /// Fixed path the current track's artwork is written to (overwritten on track change).
    let artworkFileURL: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OBSAssistants-NowPlaying", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("artwork.png")
    }()

    /// Called on every poll tick (roughly every 1s) with the latest snapshot.
    /// Invoked on the main queue.
    var onUpdate: ((NowPlayingInfo) -> Void)?

    private let queue = DispatchQueue(label: "com.obsassistants.nowplaying.musicpoller")
    private var timer: DispatchSourceTimer?
    private var lastTrackId: String = ""
    private var artworkVersion: Int = 0
    private(set) var latest: NowPlayingInfo = .idle

    /// Set from NowPlayingState (main actor) whenever the "Silenciar
    /// automaticamente músicas com DRM no stream" toggle changes — read
    /// here, on this poller's own queue, to compute `drmAudioSilenced`
    /// for each snapshot without crossing actor isolation. Lock-protected
    /// since it's written from the main actor and read from `queue`.
    var drmProtectionEnabled: Bool {
        get { drmLock.lock(); defer { drmLock.unlock() }; return _drmProtectionEnabled }
        set { drmLock.lock(); _drmProtectionEnabled = newValue; drmLock.unlock() }
    }
    private let drmLock = NSLock()
    private var _drmProtectionEnabled = false

    /// Confirmed against Music.app's real AppleScript dictionary
    /// (`com.apple.Music.sdef`) rather than guessed: `cloud status` of
    /// `subscription` is Apple Music streaming catalog content — rented,
    /// not owned, and FairPlay-DRM-protected for playback. `kind`
    /// containing "Protected" catches the older (pre-2009) FairPlay
    /// purchased-track DRM, still occasionally present in older libraries.
    ///
    /// **`tell application "Music"` can hang indefinitely when Music.app
    /// isn't running** — confirmed by sampling a genuinely stuck process:
    /// the very first execution sat forever deep inside
    /// `TUASApplication::Send`, on the main thread as much as any
    /// background queue (ruled that out directly too, with an isolated
    /// harness outside this app). The read most consistent with that
    /// evidence: resolving/launching the target app to service the `tell`
    /// — needed even just to *compile* a script mentioning it — can itself
    /// hang for this specific app/LSUIElement-caller combination, and
    /// AppleScript's own `with timeout of N seconds` does **not** bound
    /// that (verified: adding it here changed nothing) — it only bounds
    /// Apple Events sent *during* execution, not this earlier resolution
    /// step. The actual fix is `pollTick()` checking
    /// `NSWorkspace.runningApplications` — plain Swift, no Apple Events —
    /// **before** ever executing this script, so it's simply never asked
    /// to `tell` an app that isn't running in the first place.
    private let statusScript: NSAppleScript = {
        let source = """
        set outStr to "STOPPED|||||||||||"
        try
                tell application "Music"
                    set curState to player state
                    if curState is stopped then
                        return "STOPPED|||||||||||"
                    end if
                    set trackName to ""
                    set trackArtist to ""
                    set trackAlbum to ""
                    set trackDuration to 0
                    set trackPosition to 0
                    set trackId to "none"
                    try
                        with timeout of 2 seconds
                            set trackName to name of current track
                            set trackArtist to artist of current track
                            set trackAlbum to album of current track
                            set trackDuration to duration of current track
                            set trackPosition to player position
                            set trackId to (database ID of current track) as string
                        end timeout
                    end try
                    set trackKindStr to ""
                    try
                        with timeout of 2 seconds
                            set trackKindStr to kind of current track
                        end timeout
                    end try
                    set trackCloudStr to ""
                    try
                        with timeout of 2 seconds
                            set trackCloudStr to (cloud status of current track) as string
                        end timeout
                    end try
                    set stateStr to "PAUSED"
                    if curState is playing then set stateStr to "PLAYING"
                    set outStr to stateStr & "|||" & trackName & "|||" & trackArtist & "|||" & trackAlbum & "|||" & (trackDuration as string) & "|||" & (trackPosition as string) & "|||" & trackId & "|||" & trackKindStr & "|||" & trackCloudStr
                end tell
        end try
        return outStr
        """
        return NSAppleScript(source: source)!
    }()

    /// `pause`, not `stop` — pause keeps the playback position (so resuming
    /// picks up where it left off); `stop` would reset it to the start.
    /// Used only when DRM protection is on, a DRM'd track is playing, and
    /// "Também silenciar no Mac" is also on — there'd be no audio outlet
    /// left at all (stream silenced for rights, local already muted), so
    /// pausing is less surprising than letting it "play" into total
    /// silence. See NowPlayingState.applyDRMPolicy.
    private let pauseScript = NSAppleScript(source: "with timeout of 2 seconds\n tell application \"Music\" to pause\nend timeout")!

    private let artworkScript: NSAppleScript = {
        let source = """
        tell application "Music"
            try
                if (count of artworks of current track) > 0 then
                    return data of artwork 1 of current track
                end if
            end try
        end tell
        return missing value
        """
        return NSAppleScript(source: source)!
    }()

    func start() {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: DispatchTime.now(), repeating: 1.0)
        t.setEventHandler { [weak self] in
            self?.pollTick()
        }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// **`NSAppleScript` must run on the main thread** — confirmed the hard
    /// way: executed from this poller's own background `queue` (as every
    /// script here always was, pre-dating the DRM feature), a call that
    /// takes 0.17s on the main thread either hung indefinitely or took 8+
    /// seconds off it, reproduced with a minimal isolated harness outside
    /// this app entirely. Apple's own docs say the same thing. This
    /// previously went unnoticed because it only actually surfaces once
    /// Music.app isn't running — every earlier test in this session had it
    /// open. `queue` still owns the *timer* (so the 1s cadence itself
    /// doesn't touch the main thread's scheduling), but each tick now hops
    /// to main for the actual `executeAndReturnError` call, same as
    /// `extractArtwork()` and `pausePlayback()` below.
    private func runOnMainThread<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
    }

    /// Plain `NSWorkspace` check — no Apple Events at all, so it can never
    /// hang the way `tell application "Music"` can when it isn't running
    /// (see `statusScript`'s doc comment). This is what actually makes
    /// that safe to call: by the time `pollTick()` reaches it, Music.app
    /// is confirmed running.
    private func isMusicRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Music" }
    }

    private func pollTick() {
        guard isMusicRunning() else {
            lastTrackId = ""
            publish(.idle)
            return
        }

        var errorDict: NSDictionary?
        let descriptor = runOnMainThread { statusScript.executeAndReturnError(&errorDict) }
        if let errorDict {
            FileHandle.standardError.write(Data("AppleScript error: \(errorDict)\n".utf8))
        }
        guard let result = descriptor.stringValue else {
            publish(.idle)
            return
        }

        let parts = result.components(separatedBy: "|||")
        guard parts.count >= 1 else {
            publish(.idle)
            return
        }

        let stateToken = parts[0]
        if stateToken == "STOPPED" || parts.count < 7 {
            lastTrackId = ""
            publish(.idle)
            return
        }

        let title = parts[1]
        let artist = parts[2]
        let album = parts[3]
        // AppleScript's "as string" coercion of real numbers is locale-sensitive
        // (e.g. "84,89" under a comma-decimal locale), so normalize before parsing.
        let durationSeconds = Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0
        let positionSeconds = Double(parts[5].replacingOccurrences(of: ",", with: ".")) ?? 0
        let trackId = parts[6]
        let isPlaying = (stateToken == "PLAYING")
        let kindStr = parts.count > 7 ? parts[7] : ""
        let cloudStatusStr = parts.count > 8 ? parts[8] : ""
        let hasDRM = cloudStatusStr == "subscription" || kindStr.localizedCaseInsensitiveContains("protected")
        let drmAudioSilenced = hasDRM && drmProtectionEnabled

        if trackId != lastTrackId {
            lastTrackId = trackId
            extractArtwork()
        }

        let hasArtwork = FileManager.default.fileExists(atPath: artworkFileURL.path)
        let info = NowPlayingInfo(
            title: title,
            artist: artist,
            album: album,
            positionMs: Int(positionSeconds * 1000),
            durationMs: Int(durationSeconds * 1000),
            isPlaying: isPlaying,
            playbackState: isPlaying ? PlaybackState.playing.rawValue : PlaybackState.paused.rawValue,
            artworkUrl: hasArtwork ? "/artwork.png?v=\(artworkVersion)&t=\(trackId)" : nil,
            trackId: trackId,
            serverTimeMs: Int(Date().timeIntervalSince1970 * 1000),
            hasDRM: hasDRM,
            drmAudioSilenced: drmAudioSilenced
        )
        publish(info)
    }

    /// See `pauseScript`'s doc comment. Fire-and-forget, on this poller's
    /// own queue — never called from the AppleScript-executing thread
    /// itself since it's invoked from NowPlayingState (main actor).
    func pausePlayback() {
        queue.async { [weak self] in
            guard let self else { return }
            var errorDict: NSDictionary?
            _ = self.runOnMainThread { self.pauseScript.executeAndReturnError(&errorDict) }
            if let errorDict {
                FileHandle.standardError.write(Data("[DRM] AppleScript pause error: \(errorDict)\n".utf8))
            }
        }
    }

    private func extractArtwork() {
        var errorDict: NSDictionary?
        let descriptor = runOnMainThread { artworkScript.executeAndReturnError(&errorDict) }
        let data = descriptor.data
        guard !data.isEmpty, let image = NSImage(data: data) else {
            try? FileManager.default.removeItem(at: artworkFileURL)
            return
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return
        }
        do {
            try png.write(to: artworkFileURL, options: .atomic)
            artworkVersion += 1
        } catch {
            // Non-fatal: overlay will just keep showing the previous artwork.
        }
    }

    private func publish(_ info: NowPlayingInfo) {
        latest = info
        let callback = onUpdate
        DispatchQueue.main.async {
            callback?(info)
        }
    }
}
