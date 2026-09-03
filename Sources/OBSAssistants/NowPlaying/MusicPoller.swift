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

    private let statusScript: NSAppleScript = {
        let source = """
        set outStr to "STOPPED|||||||||"
        try
            tell application "System Events"
                set isRunning to (name of processes) contains "Music"
            end tell
            if isRunning then
                tell application "Music"
                    set curState to player state
                    if curState is stopped then
                        return "STOPPED|||||||||"
                    end if
                    set trackName to ""
                    set trackArtist to ""
                    set trackAlbum to ""
                    set trackDuration to 0
                    set trackPosition to 0
                    set trackId to "none"
                    try
                        set trackName to name of current track
                        set trackArtist to artist of current track
                        set trackAlbum to album of current track
                        set trackDuration to duration of current track
                        set trackPosition to player position
                        set trackId to (database ID of current track) as string
                    end try
                    set stateStr to "PAUSED"
                    if curState is playing then set stateStr to "PLAYING"
                    set outStr to stateStr & "|||" & trackName & "|||" & trackArtist & "|||" & trackAlbum & "|||" & (trackDuration as string) & "|||" & (trackPosition as string) & "|||" & trackId
                end tell
            end if
        end try
        return outStr
        """
        return NSAppleScript(source: source)!
    }()

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

    private func pollTick() {
        var errorDict: NSDictionary?
        let descriptor = statusScript.executeAndReturnError(&errorDict)
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
            serverTimeMs: Int(Date().timeIntervalSince1970 * 1000)
        )
        publish(info)
    }

    private func extractArtwork() {
        var errorDict: NSDictionary?
        let descriptor = artworkScript.executeAndReturnError(&errorDict)
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
