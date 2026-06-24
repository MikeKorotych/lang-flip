import AVFoundation
import CoreAudio
import Foundation

final class VoiceRecorder: NSObject, AVAudioRecorderDelegate {
    static let shared = VoiceRecorder()

    private var recorder: AVAudioRecorder?
    private var lastAveragePower: Float = -160
    private var lastPeakPower: Float = -160
    private(set) var lastRecordingURL: URL?
    private(set) var lastError: String?
    private(set) var startedAt: Date?
    private(set) var activeInputName: String = VoiceRecorder.defaultInputDeviceName()

    private override init() {
        super.init()
    }

    var isRecording: Bool {
        recorder?.isRecording == true
    }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    var averagePower: Float {
        updateMeters()
        return lastAveragePower
    }

    var peakPower: Float {
        updateMeters()
        return lastPeakPower
    }

    var normalizedAveragePower: Double {
        Self.normalizedPower(averagePower)
    }

    var normalizedPeakPower: Double {
        Self.normalizedPower(peakPower)
    }

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

    @discardableResult
    func start() -> Bool {
        guard !isRecording else { return true }
        guard PermissionStatus.hasMicrophone() else {
            lastError = "Microphone permission is not granted."
            notify()
            return false
        }

        do {
            let url = try Self.makeRecordingURL()
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                lastError = "Could not start microphone recording."
                notify()
                return false
            }
            self.recorder = recorder
            lastRecordingURL = url
            lastError = nil
            startedAt = Date()
            activeInputName = Self.defaultInputDeviceName()
            lastAveragePower = -160
            lastPeakPower = -160
            notify()
            return true
        } catch {
            lastError = error.localizedDescription
            notify()
            return false
        }
    }

    func stop() {
        guard let recorder else { return }
        recorder.stop()
        self.recorder = nil
        startedAt = nil
        lastAveragePower = -160
        lastPeakPower = -160
        notify()
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        lastError = error?.localizedDescription ?? "Audio recorder encode error."
        self.recorder = nil
        startedAt = nil
        lastAveragePower = -160
        lastPeakPower = -160
        notify()
    }

    private func notify() {
        NotificationCenter.default.post(name: .langFlipVoiceRecorderChanged, object: self)
    }

    private func updateMeters() {
        guard let recorder, recorder.isRecording else {
            lastAveragePower = -160
            lastPeakPower = -160
            return
        }
        recorder.updateMeters()
        lastAveragePower = recorder.averagePower(forChannel: 0)
        lastPeakPower = recorder.peakPower(forChannel: 0)
    }

    private static func normalizedPower(_ db: Float) -> Double {
        guard db > -80 else { return 0 }
        let clamped = min(0, max(-80, db))
        return pow(10, Double(clamped) / 40)
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
