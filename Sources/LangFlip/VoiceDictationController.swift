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
    private(set) var isTranscribing = false
    private var recordingStartedAt: Date?
    private var recordingApp: String?

    private init() {}

    func start(mode: Mode) {
        guard !isRecording, !isTranscribing else { return }
        guard PermissionStatus.hasMicrophone() else {
            PermissionStatus.requestMicrophone()
            PermissionStatus.openMicrophonePane()
            Notifications.show(title: "Sayful Dictation", body: "Microphone access is required for dictation.")
            return
        }
        guard VoiceRecorder.shared.start() else {
            Notifications.show(title: "Dictation failed", body: VoiceRecorder.shared.lastError ?? "Could not start recording.")
            return
        }
        self.mode = mode
        isRecording = true
        recordingStartedAt = Date()
        // Frontmost app now is the dictation target (global hotkeys don't focus
        // LangFlip). Captured here for the usage-by-app breakdown in Insights.
        recordingApp = NSWorkspace.shared.frontmostApplication?.localizedName
        notifyStateChanged()
        Sound.playFlip()
        // No FlipOverlay here — the dictation island is the visual feedback for
        // speech-to-text (live waves while recording). FlipOverlay is reserved for
        // layout-flip / AI text fixes. The routine banner is opt-in (off by default).
        if Settings.shared.dictationNotifications {
            let body = mode == .pushToTalk
                ? "Recording while \(Settings.shared.dictationPushToTalkShortcut.displayName) is held."
                : "Recording. Press \(Settings.shared.dictationHandsFreeShortcut.displayName) to stop."
            Notifications.show(title: "Dictation", body: body)
        }
    }

    func stopAndTranscribe() {
        guard isRecording else { return }
        VoiceRecorder.shared.stop()
        isRecording = false
        mode = nil
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) }
        recordingStartedAt = nil
        let app = recordingApp
        recordingApp = nil

        guard let audioURL = VoiceRecorder.shared.lastRecordingURL else {
            notifyStateChanged()
            Notifications.show(title: "Dictation failed", body: "No recording was saved.")
            return
        }

        beginTranscription(audioURL: audioURL, duration: duration, app: app)
    }

    /// Re-run transcription on the last recording after a cancel — backs the
    /// island's "Transcript cancelled / Undo" toast. `cancel()` only stops the
    /// recorder, so the audio file is still on disk.
    func undoCancel() {
        guard !isRecording, !isTranscribing,
              let audioURL = VoiceRecorder.shared.lastRecordingURL else { return }
        beginTranscription(audioURL: audioURL, duration: nil, app: nil)
    }

    private func beginTranscription(audioURL: URL, duration: Double?, app: String?) {
        isTranscribing = true
        // The island shows the transcribing state; the banner is opt-in.
        notifyStateChanged()
        if Settings.shared.dictationNotifications {
            Notifications.show(title: "Dictation", body: "Transcribing...")
        }

        Task {
            do {
                let text = try await Self.transcribe(audioURL: audioURL)
                await MainActor.run {
                    self.isTranscribing = false
                    self.insert(text, duration: duration, app: app)
                    self.notifyStateChanged()
                }
            } catch {
                await MainActor.run {
                    self.isTranscribing = false
                    self.notifyStateChanged()
                    Notifications.show(title: "Transcription failed", body: error.localizedDescription)
                }
            }
        }
    }

    /// Discard an in-progress recording without transcribing or inserting.
    /// Backs the island's ✕ (cancel) control.
    func cancel() {
        guard isRecording else { return }
        VoiceRecorder.shared.stop()
        isRecording = false
        mode = nil
        recordingStartedAt = nil
        recordingApp = nil
        notifyStateChanged()
        NotificationCenter.default.post(name: .langFlipDictationCancelled, object: nil)
    }

    func toggleRecording() {
        if isRecording {
            stopAndTranscribe()
        } else {
            start(mode: .toggle)
        }
    }

    private func notifyStateChanged() {
        NotificationCenter.default.post(name: .langFlipDictationStateChanged, object: nil)
    }

    private static func transcribe(audioURL: URL) async throws -> String {
        if Settings.shared.dictationTranscriptionBackend == .cloud {
            // Sayful Cloud (signed in) → backend proxy, no provider key needed.
            // Otherwise fall back to the user's own key (BYOK).
            if Settings.shared.aiMode == .backend, SupabaseBackendAuth.shared.isSignedIn {
                let data = try Data(contentsOf: audioURL)
                let result = try await HTTPBackendClient.shared.transcribe(
                    BackendTranscribeRequest(audio: data, filename: audioURL.lastPathComponent,
                                             language: nil, model: nil))
                return result.text
            }
            return try await CloudTranscriber.transcribe(audioURL: audioURL)
        }
        return try await WhisperTranscriber.transcribe(
            audioURL: audioURL,
            language: Settings.shared.whisperLanguage
        )
    }

    private func insert(_ text: String, duration: Double? = nil, app: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Notifications.show(title: "Dictation", body: "No speech was recognized.")
            return
        }

        // Expand any snippet triggers automatically before inserting.
        let cleaned = SnippetStore.shared.expand(trimmed)

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cleaned, forType: .string)
        postCommandV()
        Sound.playFlip()
        DictationHistory.shared.add(cleaned, duration: duration, app: app)
        // The text appears at the cursor and the sound confirms it — the "inserted"
        // banner is opt-in (off by default) to keep dictation quiet.
        if Settings.shared.dictationNotifications {
            Notifications.show(title: "Dictation inserted", body: String(cleaned.prefix(80)))
        }
    }

    /// Put `text` on the clipboard and paste it into the frontmost app. Used by
    /// the menubar's "Paste last transcript" — unlike `insert`, it doesn't log
    /// to history or play feedback (it's re-pasting something already captured).
    func pasteText(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cleaned, forType: .string)
        postCommandV()
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
