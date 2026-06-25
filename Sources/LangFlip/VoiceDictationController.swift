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
        // Recording runs for seconds while the network sits idle — warm the STT
        // connection now so the upload-after-stop reuses a hot TLS connection.
        Self.prewarmSTTConnection()
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
                let raw = try await Self.transcribe(audioURL: audioURL)
                // Tidy formatting on longer dictations (punctuation, merging
                // pause-split fragments, lists) without changing the words. Stays
                // in the transcribing state so the island keeps its spinner; falls
                // back to the raw transcript on any failure / when unavailable.
                let text = await Self.autoFormat(raw)
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

    /// Warm the TLS connection for whichever STT path is active, so the POST
    /// after the user stops talking reuses it instead of paying a cold
    /// DNS+TCP+TLS handshake. Mirrors the routing in `transcribe(audioURL:)`.
    private static func prewarmSTTConnection() {
        if Settings.shared.aiMode == .backend {
            guard SupabaseBackendAuth.shared.isSignedIn else { return }
            ConnectionWarmer.warm(BackendConfig.functionsBaseURL, label: "STT")
        } else if let url = URL(string: Settings.shared.cloudSTTBaseURL) {
            ConnectionWarmer.warm(url, label: "STT")
        }
    }

    private static func transcribe(audioURL: URL) async throws -> String {
        // Dictation is cloud-only. Sayful Cloud → backend proxy (no provider
        // key; requires sign-in). Advanced/BYOK → the user's own key.
        if Settings.shared.aiMode == .backend {
            guard SupabaseBackendAuth.shared.isSignedIn else {
                throw CloudTranscriptionError.notSignedIn
            }
            let data = try Data(contentsOf: audioURL)
            // Developers (Advanced) can pin the STT model for their account;
            // everyone else sends nil and gets the backend's server default.
            let modelOverride = UserDefaults.standard.bool(forKey: "lf.showAdvancedAI")
                ? Settings.shared.cloudSTTModel : nil
            let result = try await HTTPBackendClient.shared.transcribe(
                BackendTranscribeRequest(audio: data, filename: audioURL.lastPathComponent,
                                         language: nil, model: modelOverride))
            return result.text
        }
        return try await CloudTranscriber.transcribe(audioURL: audioURL)
    }

    /// Reformat a transcript through the AI assistant (structure only, words
    /// preserved). Returns the original on any failure / when disabled / when
    /// the assistant isn't available, so dictation never breaks.
    private static func autoFormat(_ raw: String) async -> String {
        guard Settings.shared.dictationAutoFormat else { return raw }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Settings.shared.dictationAutoFormatMinChars else { return raw }

        let formatted: String? = await withCheckedContinuation { cont in
            Task { @MainActor in
                let assistant = AIAssistantManager.shared.current
                guard assistant.isReady else { cont.resume(returning: nil); return }
                assistant.formatDictation(AIDictationFormatRequest(text: trimmed)) { result in
                    if case .formatted(let t) = result { cont.resume(returning: t) }
                    else { cont.resume(returning: nil) }
                }
            }
        }
        guard let formatted, !formatted.isEmpty else { return raw }

        // Guard against the model rewriting/summarizing instead of just
        // reformatting: formatting barely changes the word count, so a large
        // deviation means it altered content — keep the raw transcript then.
        let rawWords = trimmed.split(whereSeparator: \.isWhitespace).count
        let fmtWords = formatted.split(whereSeparator: \.isWhitespace).count
        if rawWords > 0, abs(Double(fmtWords - rawWords)) / Double(rawWords) > 0.35 {
            return raw
        }
        return formatted
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
