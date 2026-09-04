import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreAudio
import AudioToolbox
import AppKit

enum AudioCaptureError: Error, CustomStringConvertible {
    case musicNotRunning
    case processObjectNotFound
    case muteTapFailed(OSStatus)
    case contentFetchFailed(String)
    case streamStartFailed(String)

    var description: String {
        switch self {
        case .musicNotRunning:
            return "O Music.app precisa estar aberto para capturar o áudio dele."
        case .processObjectNotFound:
            return "Não foi possível localizar o processo do Music.app no Core Audio."
        case .muteTapFailed(let status):
            return "Falha ao silenciar o Music.app localmente (status \(status))."
        case .contentFetchFailed(let msg):
            return "Não foi possível listar apps capturáveis (verifique a permissão de Gravação de Tela em Ajustes do Sistema > Privacidade e Segurança): \(msg)"
        case .streamStartFailed(let msg):
            return "Falha ao iniciar a captura de áudio: \(msg)"
        }
    }
}

/// Streams Music.app's audio to the overlay (for OBS) via two independently
/// controllable mechanisms — capture and local mute are two separate public
/// entry points (`startCapture`/`stopCapture`, `startMute`/`stopMute`)
/// precisely so the overlay can broadcast audio *while Music.app keeps
/// playing normally on the user's own speakers* (capture on, mute off) —
/// not just the original "silence locally, stream only" combination
/// (capture on, mute on):
///
///  - **Muting locally**: a Core Audio process tap
///    (`AudioHardwareCreateProcessTap`, macOS 14.2+) on Music.app with
///    `muteBehavior = .muted`. Its *existence* is what silences Music.app's
///    audio on the real output device — verified against a real listening
///    setup. We never actually read data from this tap (see below).
///  - **Capturing the real audio**: ScreenCaptureKit's per-application audio
///    capture (`SCStreamConfiguration.capturesAudio`, macOS 13+ — the same
///    class of API OBS's own "Application Audio Capture" source uses). This
///    reliably delivers real, non-silent samples.
///
/// Why not just one of them: the process tap's OWN captured audio came back
/// silent in extensive testing (confirmed byte-correct process/tap/format
/// wiring throughout — likely some HAL-level quirk specific to reading a
/// pure-tap private aggregate this way), while ScreenCaptureKit has no
/// "mute the source" knob at all — it's purely a capture API. Running both
/// at once has no conflict: they're independent Core Audio consumers, and
/// this is exactly the combination the user separately observed working
/// (their OBS "Apple Music" capture kept working while our mute silenced
/// their speakers).
///
/// One more wrinkle found in testing: the tap's *existence* alone isn't
/// enough to actually mute anything — it only takes effect once the tap is
/// wrapped in an aggregate device that's genuinely running (something is
/// actively reading from it). We still don't care about that data's content
/// (it came back silent, hence ScreenCaptureKit for the real audio) — an
/// AUHAL is kept running against it purely as the "someone is reading this"
/// signal, and every buffer it hands back is discarded.
@available(macOS 14.2, *)
final class AudioCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    static let outputSampleRate: Double = 48000
    static let outputChannelCount: AVAudioChannelCount = 2

    private var muteTapID: AudioObjectID = 0
    private var muteAggregateDeviceID: AudioObjectID = 0
    private var muteKeepAliveUnit: AudioUnit?
    private var muteKeepAliveScratch: AVAudioPCMBuffer?

    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: AudioCaptureEngine.outputSampleRate,
        channels: AudioCaptureEngine.outputChannelCount,
        interleaved: true
    )!
    /// Whether ScreenCaptureKit is actively capturing + broadcasting
    /// Music.app's audio — independent of `isMuted` below. Capturing this
    /// way never depended on Music.app being muted (ScreenCaptureKit's
    /// per-app capture reads the render graph regardless of output
    /// routing), which is what makes the two independently controllable at
    /// all — see the class doc comment.
    private(set) var isCapturing = false
    /// Whether Music.app is currently silenced on its normal output (the
    /// Core Audio mute tap below) — independent of `isCapturing`. Kept
    /// separate so "listen locally AND send to the stream" (capture on,
    /// mute off) and "stream only, silent locally" (capture on, mute on)
    /// are both just a combination of two independent toggles instead of
    /// one all-or-nothing switch.
    private(set) var isMuted = false

    /// Called with raw 16-bit little-endian interleaved PCM (stereo, 48kHz)
    /// as it's captured. Invoked on the stream's sample-handler queue.
    var onPCMChunk: ((Data) -> Void)?

    /// When true, `onPCMChunk` is still called every chunk (keeps the
    /// WebSocket/overlay timing alive, no audible glitch) but with the
    /// bytes zeroed out — digital silence — instead of the real captured
    /// audio. Used for the DRM auto-mute toggle: the *capture itself*
    /// keeps running (so it resumes instantly once a non-DRM track plays),
    /// only the output is muted. Lock-protected: set from NowPlayingState
    /// on the main actor, read from this engine's own sample-handler
    /// queue — see `handleCaptured`.
    var muteStreamOutput: Bool {
        get { muteStreamLock.lock(); defer { muteStreamLock.unlock() }; return _muteStreamOutput }
        set { muteStreamLock.lock(); _muteStreamOutput = newValue; muteStreamLock.unlock() }
    }
    private let muteStreamLock = NSLock()
    private var _muteStreamOutput = false

    // MARK: - Capture (ScreenCaptureKit -> onPCMChunk), independent of mute

    func startCapture(completion: @escaping (Result<Void, AudioCaptureError>) -> Void) {
        stopCapture()
        startCaptureStream(completion: completion)
    }

    func stopCapture() {
        stream?.stopCapture { _ in }
        stream = nil
        converter = nil
        isCapturing = false
    }

    // MARK: - Local mute (Core Audio process tap), independent of capture

    func startMute() throws {
        stopMute()

        guard let musicPID = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.Music")
            .first?.processIdentifier else {
            throw AudioCaptureError.musicNotRunning
        }
        guard let processObjectID = Self.findProcessObject(forPID: musicPID) else {
            throw AudioCaptureError.processObjectNotFound
        }

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        tapDescription.name = "OBS Assistants Mute Tap"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .muted

        var newTapID: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard tapStatus == noErr, newTapID != 0 else {
            throw AudioCaptureError.muteTapFailed(tapStatus)
        }
        muteTapID = newTapID

        do {
            try startMuteKeepAliveReader(tapUID: tapDescription.uuid.uuidString)
        } catch {
            destroyMuteTap()
            throw error
        }
        isMuted = true
    }

    func stopMute() {
        destroyMuteTap()
        isMuted = false
    }

    /// Tears down both, regardless of which are currently active — full
    /// cleanup on app/feature teardown.
    func stop() {
        stopCapture()
        stopMute()
    }

    private func destroyMuteTap() {
        if let unit = muteKeepAliveUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        muteKeepAliveUnit = nil
        muteKeepAliveScratch = nil
        if muteAggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(muteAggregateDeviceID)
            muteAggregateDeviceID = 0
        }
        if muteTapID != 0 {
            AudioHardwareDestroyProcessTap(muteTapID)
            muteTapID = 0
        }
    }

    /// Wraps the mute tap in a private aggregate device and keeps a minimal
    /// AUHAL running against it — not because we want its data (discarded;
    /// see the class doc comment), but because that's what actually makes
    /// the tap's `muteBehavior` take effect.
    private func startMuteKeepAliveReader(tapUID: String) throws {
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OBS Assistants Mute Keep-Alive Aggregate",
            kAudioAggregateDeviceUIDKey: "com.obsassistants.nowplaying.mutekeepalive.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: 0
                ]
            ]
        ]
        var newAggregateID: AudioObjectID = 0
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard aggregateStatus == noErr, newAggregateID != 0 else {
            throw AudioCaptureError.muteTapFailed(aggregateStatus)
        }
        muteAggregateDeviceID = newAggregateID

        var componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &componentDescription) else {
            throw AudioCaptureError.muteTapFailed(-1)
        }
        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else { throw AudioCaptureError.muteTapFailed(status) }

        var enableIO: UInt32 = 1
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableIO, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { AudioComponentInstanceDispose(unit); throw AudioCaptureError.muteTapFailed(status) }

        var disableIO: UInt32 = 0
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableIO, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { AudioComponentInstanceDispose(unit); throw AudioCaptureError.muteTapFailed(status) }

        var deviceID = muteAggregateDeviceID
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { AudioComponentInstanceDispose(unit); throw AudioCaptureError.muteTapFailed(status) }

        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &asbd, &asbdSize)
        guard status == noErr else { AudioComponentInstanceDispose(unit); throw AudioCaptureError.muteTapFailed(status) }
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, asbdSize)
        guard status == noErr else { AudioComponentInstanceDispose(unit); throw AudioCaptureError.muteTapFailed(status) }

        guard let nativeFormat = AVAudioFormat(streamDescription: &asbd) else {
            AudioComponentInstanceDispose(unit)
            throw AudioCaptureError.muteTapFailed(-1)
        }
        let maxFrames: AVAudioFrameCount = 8192
        guard let scratch = AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: maxFrames) else {
            AudioComponentInstanceDispose(unit)
            throw AudioCaptureError.muteTapFailed(-1)
        }
        muteKeepAliveScratch = scratch

        var callbackStruct = AURenderCallbackStruct(
            inputProc: audioCaptureEngineMuteKeepAliveCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { AudioComponentInstanceDispose(unit); throw AudioCaptureError.muteTapFailed(status) }

        status = AudioUnitInitialize(unit)
        guard status == noErr else { AudioComponentInstanceDispose(unit); throw AudioCaptureError.muteTapFailed(status) }

        status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            throw AudioCaptureError.muteTapFailed(status)
        }

        muteKeepAliveUnit = unit
    }

    /// Called on Core Audio's realtime IO thread — pulls and immediately
    /// discards a buffer, purely to keep the mute aggregate "alive".
    fileprivate func drainMuteKeepAlive(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frameCount: UInt32
    ) -> OSStatus {
        guard let unit = muteKeepAliveUnit, let scratch = muteKeepAliveScratch, frameCount <= scratch.frameCapacity else {
            return noErr
        }
        scratch.frameLength = scratch.frameCapacity
        return AudioUnitRender(unit, ioActionFlags, timeStamp, busNumber, frameCount, scratch.mutableAudioBufferList)
    }

    private func startCaptureStream(completion: @escaping (Result<Void, AudioCaptureError>) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self else { return }
            if let error {
                completion(.failure(.contentFetchFailed(error.localizedDescription)))
                return
            }
            guard let content else {
                completion(.failure(.contentFetchFailed("sem conteúdo compartilhável")))
                return
            }
            guard let musicApp = content.applications.first(where: { $0.bundleIdentifier == "com.apple.Music" }) else {
                completion(.failure(.musicNotRunning))
                return
            }
            guard let display = content.displays.first else {
                completion(.failure(.contentFetchFailed("nenhum display encontrado")))
                return
            }

            let filter = SCContentFilter(display: display, including: [musicApp], exceptingWindows: [])

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.sampleRate = Int(Self.outputSampleRate)
            config.channelCount = Int(Self.outputChannelCount)
            // We only care about the audio side-channel — keep the
            // mandatory video capture as cheap as possible.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.showsCursor = false

            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.obsassistants.nowplaying.scaudio"))
            } catch {
                completion(.failure(.streamStartFailed("addStreamOutput: \(error.localizedDescription)")))
                return
            }

            newStream.startCapture { [weak self] error in
                if let error {
                    completion(.failure(.streamStartFailed(error.localizedDescription)))
                    return
                }
                self?.stream = newStream
                self?.isCapturing = true
                completion(.success(()))
            }
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        handleCaptured(buffer: buffer)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isCapturing = false
        self.stream = nil
    }

    // MARK: - Conversion

    private func handleCaptured(buffer: AVAudioPCMBuffer) {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter, let onPCMChunk else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }

        var error: NSError?
        var suppliedInput = false
        let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, let int16Data = outBuffer.int16ChannelData else { return }
        let frameCount = Int(outBuffer.frameLength)
        guard frameCount > 0 else { return }

        // int16ChannelData is interleaved for an interleaved format, laid out
        // contiguously in channelData[0].
        let byteCount = frameCount * Int(targetFormat.channelCount) * MemoryLayout<Int16>.size
        let data = muteStreamOutput ? Data(count: byteCount) : Data(bytes: int16Data[0], count: byteCount)
        onPCMChunk(data)
    }

    /// Copies a `CMSampleBuffer` wrapping an `AudioBufferList` (what
    /// `.audio` stream outputs deliver) into a plain `AVAudioPCMBuffer` we
    /// own — the sample buffer's backing storage isn't guaranteed to outlive
    /// this callback, so it must be copied, not merely wrapped.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        var asbd = asbdPointer.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        var neededSize = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &neededSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard status == noErr, neededSize > 0 else { return nil }

        let rawList = UnsafeMutableRawPointer.allocate(byteCount: neededSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawList.deallocate() }
        let ablPtr = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr,
            bufferListSize: neededSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0, let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        // Must set frameLength BEFORE reading mutableAudioBufferList below —
        // AVAudioPCMBuffer reports each buffer's mDataByteSize based on
        // frameLength (which starts at 0), not frameCapacity.
        pcmBuffer.frameLength = frameCount

        let srcList = UnsafeMutableAudioBufferListPointer(ablPtr)
        let dstList = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        for i in 0..<min(srcList.count, dstList.count) {
            guard let srcData = srcList[i].mData, let dstData = dstList[i].mData else { continue }
            let bytes = min(Int(srcList[i].mDataByteSize), Int(dstList[i].mDataByteSize))
            memcpy(dstData, srcData, bytes)
        }
        withExtendedLifetime(blockBuffer) {}
        return pcmBuffer
    }

    private static func findProcessObject(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return nil }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objectIDs)
        guard status == noErr else { return nil }

        for objectID in objectIDs {
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var objectPID: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            let pidStatus = AudioObjectGetPropertyData(objectID, &pidAddress, 0, nil, &pidSize, &objectPID)
            if pidStatus == noErr, objectPID == pid {
                return objectID
            }
        }
        return nil
    }
}

/// Must be a plain, non-capturing C function pointer (AURenderCallback's
/// required convention) — forwards to the engine instance passed via
/// `inRefCon`. See `AudioCaptureEngine.drainMuteKeepAlive`.
@available(macOS 14.2, *)
private func audioCaptureEngineMuteKeepAliveCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let engine = Unmanaged<AudioCaptureEngine>.fromOpaque(inRefCon).takeUnretainedValue()
    return engine.drainMuteKeepAlive(ioActionFlags: ioActionFlags, timeStamp: inTimeStamp, busNumber: inBusNumber, frameCount: inNumberFrames)
}
