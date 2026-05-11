import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

final class VoiceDictationController {
    static let shared = VoiceDictationController()

    enum Mode {
        case pushToTalk
        case toggle
    }

    private(set) var isRecording = false
    private var mode: Mode?
    private var isTranscribing = false

    private init() {}

    func start(mode: Mode) {
        guard !isRecording, !isTranscribing else { return }
        guard PermissionStatus.hasMicrophone() else {
            PermissionStatus.requestMicrophone()
            PermissionStatus.openMicrophonePane()
            Notifications.show(title: "LangFlip Dictation", body: "Microphone access is required for dictation.")
            return
        }
        guard VoiceRecorder.shared.start() else {
            Notifications.show(title: "Dictation failed", body: VoiceRecorder.shared.lastError ?? "Could not start recording.")
            return
        }
        self.mode = mode
        isRecording = true
        Sound.playFlip()
        FlipOverlay.shared.show()
        let body = mode == .pushToTalk
            ? "Recording while \(Settings.shared.dictationPushToTalkShortcut.displayName) is held."
            : "Recording. Press \(Settings.shared.dictationHandsFreeShortcut.displayName) to stop."
        Notifications.show(title: "Dictation", body: body)
    }

    func stopAndTranscribe() {
        guard isRecording else { return }
        VoiceRecorder.shared.stop()
        isRecording = false
        mode = nil

        guard let audioURL = VoiceRecorder.shared.lastRecordingURL else {
            Notifications.show(title: "Dictation failed", body: "No recording was saved.")
            return
        }

        isTranscribing = true
        Notifications.show(title: "Dictation", body: "Transcribing...")

        Task {
            do {
                let text = try await Self.transcribe(audioURL: audioURL)
                await MainActor.run {
                    self.isTranscribing = false
                    self.insert(text)
                }
            } catch {
                await MainActor.run {
                    self.isTranscribing = false
                    Notifications.show(title: "Transcription failed", body: error.localizedDescription)
                }
            }
        }
    }

    func toggleRecording() {
        if isRecording {
            stopAndTranscribe()
        } else {
            start(mode: .toggle)
        }
    }

    private static func transcribe(audioURL: URL) async throws -> String {
        try await WhisperTranscriber.transcribe(
            audioURL: audioURL,
            language: Settings.shared.whisperLanguage
        )
    }

    private func insert(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            Notifications.show(title: "Dictation", body: "No speech was recognized.")
            return
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cleaned, forType: .string)
        postCommandV()
        Sound.playFlip()
        FlipOverlay.shared.show()
        Notifications.show(title: "Dictation inserted", body: String(cleaned.prefix(80)))
    }

    private func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let key = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
