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
    private var sttReservation: BackendSTTReserveResult?
    private var sttReservationTask: Task<Void, Never>?

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
        prepareSTTReservation()
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
        let reservationID = sttReservation?.reservation.id
        sttReservationTask?.cancel()
        sttReservationTask = nil
        sttReservation = nil

        guard let audioURL = VoiceRecorder.shared.lastRecordingURL else {
            notifyStateChanged()
            Notifications.show(title: "Dictation failed", body: "No recording was saved.")
            return
        }

        beginTranscription(audioURL: audioURL, duration: duration, app: app, reservationID: reservationID)
    }

    /// Re-run transcription on the last recording after a cancel — backs the
    /// island's "Transcript cancelled / Undo" toast. `cancel()` only stops the
    /// recorder, so the audio file is still on disk.
    func undoCancel() {
        guard !isRecording, !isTranscribing,
              let audioURL = VoiceRecorder.shared.lastRecordingURL else { return }
        beginTranscription(audioURL: audioURL, duration: nil, app: nil, reservationID: nil)
    }

    private func beginTranscription(audioURL: URL, duration: Double?, app: String?, reservationID: String?) {
        isTranscribing = true
        // The island shows the transcribing state; the banner is opt-in.
        notifyStateChanged()
        if Settings.shared.dictationNotifications {
            Notifications.show(title: "Dictation", body: "Transcribing...")
        }

        Task {
            do {
                let raw = try await self.transcribe(audioURL: audioURL, reservationID: reservationID)
                let personalizedRaw = await MainActor.run {
                    PersonalDictionaryStore.shared.apply(to: raw)
                }
                // Tidy formatting on longer dictations (punctuation, merging
                // pause-split fragments, lists) without changing the words. Stays
                // in the transcribing state so the island keeps its spinner; falls
                // back to the raw transcript on any failure / when unavailable.
                let formatted = await Self.autoFormat(personalizedRaw, duration: duration)
                let text = await MainActor.run {
                    PersonalDictionaryStore.shared.apply(to: formatted)
                }
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
        sttReservationTask?.cancel()
        sttReservationTask = nil
        sttReservation = nil
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

    private func prepareSTTReservation() {
        sttReservationTask?.cancel()
        sttReservation = nil
        guard Settings.shared.aiMode == .backend,
              SupabaseBackendAuth.shared.isSignedIn
        else { return }

        let modelOverride = Self.backendSTTModelOverride()

        sttReservationTask = Task { [weak self] in
            do {
                let result = try await HTTPBackendClient.shared.reserveSTT(
                    BackendSTTReserveRequest(model: modelOverride)
                )
                guard !Task.isCancelled else { return }
                guard let controller = self else { return }
                await MainActor.run {
                    guard controller.isRecording else { return }
                    controller.sttReservation = result
                }
                NetworkLatency.log.info(
                    "STT reserve=ok model=\(result.model, privacy: .public)"
                )
            } catch {
                NetworkLatency.log.info(
                    "STT reserve=failed \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func transcribe(audioURL: URL, reservationID: String?) async throws -> String {
        // Dictation is cloud-only. Sayful Cloud → backend proxy (no provider
        // key; requires sign-in). Advanced/BYOK → the user's own key.
        if Settings.shared.aiMode == .backend {
            guard SupabaseBackendAuth.shared.isSignedIn else {
                throw CloudTranscriptionError.notSignedIn
            }
            let upload = try STTAudioUploadPreparer.prepareBackendUpload(from: audioURL)
            defer { upload.cleanup() }
            // Developers (Advanced) can pin the STT model for their account;
            // everyone else sends nil and gets the backend's server default.
            let modelOverride = Self.backendSTTModelOverride()

            let request = BackendTranscribeRequest(audio: upload.data,
                                                   filename: upload.filename,
                                                   language: nil,
                                                   model: modelOverride,
                                                   reservationID: reservationID)
            let result: BackendTextResult
            do {
                result = try await HTTPBackendClient.shared.transcribe(request)
            } catch {
                guard reservationID != nil else { throw error }
                NetworkLatency.log.info(
                    "STT reserve=fallback \(error.localizedDescription, privacy: .public)"
                )
                result = try await HTTPBackendClient.shared.transcribe(
                    BackendTranscribeRequest(audio: upload.data,
                                             filename: upload.filename,
                                             language: nil,
                                             model: modelOverride)
                )
            }
            return result.text
        }
        return try await CloudTranscriber.transcribe(audioURL: audioURL)
    }

    private static func backendSTTModelOverride() -> String? {
        guard UserDefaults.standard.bool(forKey: "lf.showAdvancedAI") else { return nil }
        let model = Settings.shared.cloudSTTModel
        // Sayful Cloud default. Omitting the override lets the backend use the
        // server-side default and keeps Developer UI aligned with production.
        if model == "groq/whisper-large-v3" { return nil }
        return model
    }

    /// Reformat a transcript through the AI assistant (structure only, words
    /// preserved). Returns the original on any failure / when disabled / when
    /// the assistant isn't available, so dictation never breaks.
    private static func autoFormat(_ raw: String, duration: Double?) async -> String {
        guard Settings.shared.dictationAutoFormat else { return raw }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawWords = trimmed.split(whereSeparator: \.isWhitespace).count
        let longEnoughByDuration = (duration ?? 0) >= Settings.shared.dictationAutoFormatMinDuration
        let longEnoughByWords = rawWords >= Settings.shared.dictationAutoFormatMinWords
        guard longEnoughByDuration || longEnoughByWords else { return raw }

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
        let beforeContext = FocusedTextReader.current()
        let appBundleID = AppContext.frontmostBundleID()

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cleaned, forType: .string)
        postCommandV()
        Sound.playFlip()
        DictationCorrectionLearner.shared.recordInsertion(
            text: cleaned,
            beforeContext: beforeContext,
            appBundleID: appBundleID
        )
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
