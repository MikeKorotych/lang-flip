import AVFoundation
import CoreAudio
import Foundation

/// Records dictation audio to a 16 kHz mono WAV. Uses AVAudioEngine (not
/// AVAudioRecorder) so it can capture from a user-chosen input device without
/// touching the macOS system-default input — app-scoped microphone selection,
/// like Wispr Flow. The chosen device is persisted in Settings as a stable
/// `uniqueID`; empty means "follow the system default".
final class VoiceRecorder: NSObject {
    static let shared = VoiceRecorder()

    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    /// Guards `audioFile` / `converter` / the power levels, which are touched by
    /// the audio render thread (the input tap) and the main thread (stop/teardown
    /// + the VU-meter reads). Prevents a use-after-free when teardown releases the
    /// file while a buffer is still in flight.
    private let renderLock = NSLock()

    private var lastAveragePower: Float = -160
    private var lastPeakPower: Float = -160
    private(set) var lastRecordingURL: URL?
    private(set) var lastError: String?
    private(set) var startedAt: Date?
    private(set) var activeInputName: String = VoiceRecorder.defaultInputDeviceName()

    private override init() {
        super.init()
    }

    var isRecording: Bool { engine.isRunning && audioFile != nil }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    private var levels: (avg: Float, peak: Float) {
        renderLock.lock(); defer { renderLock.unlock() }
        return (lastAveragePower, lastPeakPower)
    }
    var averagePower: Float { levels.avg }
    var peakPower: Float { levels.peak }
    var normalizedAveragePower: Double { Self.normalizedPower(levels.avg) }
    var normalizedPeakPower: Double { Self.normalizedPower(levels.peak) }

    static var inputDevices: [AVCaptureDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }

        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    static func defaultInputDeviceName() -> String {
        coreAudioDefaultInputName()
            ?? AVCaptureDevice.default(for: .audio)?.localizedName
            ?? "System default"
    }

    /// Display name for the currently preferred input (or the system default
    /// when none is chosen / the chosen device is unplugged).
    static func selectedInputDeviceName() -> String {
        let uid = Settings.shared.preferredInputDeviceUID
        if !uid.isEmpty, let device = AVCaptureDevice(uniqueID: uid) {
            return device.localizedName
        }
        return defaultInputDeviceName()
    }

    @discardableResult
    func start() -> Bool {
        guard !isRecording else { return true }
        guard PermissionStatus.hasMicrophone() else {
            lastError = "Microphone permission is not granted."
            notify()
            return false
        }

        do {
            // App-scoped device selection: point the engine's input node at the
            // chosen device (no effect on the system default). Best-effort —
            // fall back to the default input if it can't be applied.
            applyPreferredInputDevice()

            let input = engine.inputNode
            let tapFormat = input.outputFormat(forBus: 0)
            guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
                lastError = "No audio input is available."
                notify()
                return false
            }

            let url = try Self.makeRecordingURL()
            // 16 kHz mono 16-bit WAV — what the cloud STT models expect.
            let fileSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            let file = try AVAudioFile(forWriting: url, settings: fileSettings)
            // Write in the file's processing format; AVAudioFile encodes to the
            // on-disk int16 representation. The converter resamples/downmixes the
            // hardware buffers (e.g. 48 kHz stereo float) into it.
            guard let conv = AVAudioConverter(from: tapFormat, to: file.processingFormat) else {
                lastError = "Could not set up audio conversion."
                notify()
                return false
            }
            audioFile = file
            converter = conv
            // Initialise the meter before the tap starts firing on the render thread.
            lastAveragePower = -160
            lastPeakPower = -160

            input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
                self?.process(buffer)
            }

            engine.prepare()
            try engine.start()

            lastRecordingURL = url
            lastError = nil
            startedAt = Date()
            activeInputName = Self.selectedInputDeviceName()
            notify()
            return true
        } catch {
            teardown()
            lastError = error.localizedDescription
            notify()
            return false
        }
    }

    func stop() {
        guard engine.isRunning || audioFile != nil else { return }
        teardown()
        startedAt = nil
        notify()
    }

    /// Stop recording and close the file. Order matters: remove the tap first so
    /// no new buffers are delivered, stop the engine, then release the file +
    /// converter UNDER the lock — so a buffer already in flight on the render
    /// thread can't write to a freed file, and the last write completes before we
    /// drop the file (which finalizes the WAV header for the caller).
    private func teardown() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        renderLock.lock()
        audioFile = nil
        converter = nil
        lastAveragePower = -160
        lastPeakPower = -160
        renderLock.unlock()
    }

    /// Runs on the audio render thread. The lock pairs with `teardown()` so the
    /// file/converter can't be freed mid-write.
    private func process(_ buffer: AVAudioPCMBuffer) {
        renderLock.lock()
        defer { renderLock.unlock() }

        meter(buffer)
        guard let converter, let audioFile else { return }

        let ratio = audioFile.processingFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: capacity) else { return }

        var fed = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, out.frameLength > 0 else { return }
        try? audioFile.write(from: out)
    }

    /// Cheap VU meter from the raw float buffer (RMS + peak → dBFS).
    private func meter(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var sumSquares: Float = 0
        var peak: Float = 0
        for i in 0..<frames {
            let sample = abs(channel[i])
            sumSquares += sample * sample
            if sample > peak { peak = sample }
        }
        let rms = sqrt(sumSquares / Float(frames))
        lastAveragePower = 20 * log10(max(rms, 1e-7))
        lastPeakPower = 20 * log10(max(peak, 1e-7))
    }

    private func notify() {
        // Observers are SwiftUI views (`.onReceive`), so always post on main —
        // `stop()` is now torn down off the main thread (see stopAndTranscribe).
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .langFlipVoiceRecorderChanged, object: self)
        }
    }

    private static func normalizedPower(_ db: Float) -> Double {
        guard db > -80 else { return 0 }
        let clamped = min(0, max(-80, db))
        return pow(10, Double(clamped) / 40)
    }

    /// Point the engine's input node at the preferred device, if one is set and
    /// resolvable. Best-effort: any failure leaves the engine on the default input.
    private func applyPreferredInputDevice() {
        let uid = Settings.shared.preferredInputDeviceUID
        guard !uid.isEmpty, let deviceID = Self.audioDeviceID(forUID: uid) else { return }
        do {
            try engine.inputNode.auAudioUnit.setDeviceID(deviceID)
        } catch {
            // Chosen device unavailable (e.g. unplugged) — fall back to default.
        }
    }

    /// Resolve a CoreAudio `AudioDeviceID` from an `AVCaptureDevice.uniqueID`
    /// (which, for audio devices, is the CoreAudio device UID string).
    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &devices
        ) == noErr else { return nil }

        for device in devices {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfUID: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &size, &cfUID) == noErr,
                  let deviceUID = cfUID?.takeRetainedValue() as String? else { continue }
            if deviceUID == uid { return device }
        }
        return nil
    }

    private static func coreAudioDefaultInputName() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedName: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &nameAddress,
            0,
            nil,
            &size,
            &unmanagedName
        ) == noErr else {
            return nil
        }
        return unmanagedName?.takeUnretainedValue() as String?
    }

    private static func makeRecordingURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("Sayful/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return dir.appendingPathComponent("dictation-\(stamp).wav")
    }
}
