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
    private var failedTranscription: FailedTranscription?
    private var pendingCancelledRecordingURL: URL?

    private struct FailedTranscription {
        let audioURL: URL
        let duration: Double?
        let app: String?
        let historyEntryID: UUID?
        let insertOnSuccess: Bool
    }

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
        failedTranscription = nil
        recordingStartedAt = Date()
        // Recording runs for seconds while the network sits idle — warm the STT
        // connection now so the upload-after-stop reuses a hot TLS connection.
        Self.prewarmSTTConnection()
        prepareSTTReservation()
        recordingApp = NSWorkspace.shared.frontmostApplication?.localizedName
        notifyStateChanged()
        Sound.playFlip()
        // No FlipOverlay or system banner here — the dictation island is the
        // visual feedback for speech-to-text. Notifications are reserved for
        // actionable failures such as no recognized speech.
    }

    func stopAndTranscribe() {
        guard isRecording else { return }
        isRecording = false
        isTranscribing = true
        mode = nil
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) }
        recordingStartedAt = nil
        let app = recordingApp
        recordingApp = nil
        let reservationID = sttReservation?.reservation.id
        sttReservationTask?.cancel()
        sttReservationTask = nil
        sttReservation = nil

        notifyStateChanged()

        // Tear the recorder down off the main thread so the AVAudioEngine HAL
        // deactivation (tens of ms) doesn't contend with the recording→transcribing
        // transition on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            VoiceRecorder.shared.stop()
            let audioURL = VoiceRecorder.shared.lastRecordingURL
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let audioURL else {
                    self.isTranscribing = false
                    self.notifyStateChanged()
                    if Settings.shared.dictationNotifications {
                        Notifications.show(title: "Dictation failed", body: "No recording was saved.")
                    }
                    return
                }
                self.beginTranscription(audioURL: audioURL,
                                        duration: duration,
                                        app: app,
                                        reservationID: reservationID,
                                        stateAlreadyTranscribing: true)
            }
        }
    }

    /// Re-run transcription on a just-cancelled recording while the island's
    /// Undo toast is still visible. When the toast expires, the file is deleted.
    func undoCancel() {
        guard !isRecording, !isTranscribing,
              let audioURL = pendingCancelledRecordingURL
        else { return }
        pendingCancelledRecordingURL = nil
        beginTranscription(audioURL: audioURL, duration: nil, app: nil, reservationID: nil)
    }

    func discardPendingCancelledRecording() {
        guard let audioURL = pendingCancelledRecordingURL else { return }
        pendingCancelledRecordingURL = nil
        VoiceRecorder.shared.discardRecording(at: audioURL)
    }

    func retryFailedTranscription() {
        guard !isRecording, !isTranscribing,
              let failedTranscription,
              FileManager.default.fileExists(atPath: failedTranscription.audioURL.path)
        else { return }
        if let historyEntryID = failedTranscription.historyEntryID {
            DictationHistory.shared.markRetrying(id: historyEntryID)
        }
        beginTranscription(audioURL: failedTranscription.audioURL,
                           duration: failedTranscription.duration,
                           app: failedTranscription.app,
                           reservationID: nil,
                           replacingHistoryEntryID: failedTranscription.historyEntryID,
                           insertOnSuccess: failedTranscription.insertOnSuccess)
    }

    func retryFailedTranscription(entry: DictationEntry) {
        guard !isRecording, !isTranscribing,
              entry.isFailed,
              let audioURL = entry.audioURL,
              FileManager.default.fileExists(atPath: audioURL.path)
        else { return }
        failedTranscription = FailedTranscription(audioURL: audioURL,
                                                  duration: entry.duration,
                                                  app: entry.app,
                                                  historyEntryID: entry.id,
                                                  insertOnSuccess: false)
        DictationHistory.shared.markRetrying(id: entry.id)
        beginTranscription(audioURL: audioURL,
                           duration: entry.duration,
                           app: entry.app,
                           reservationID: nil,
                           replacingHistoryEntryID: entry.id,
                           insertOnSuccess: false)
    }

    private func beginTranscription(audioURL: URL,
                                    duration: Double?,
                                    app: String?,
                                    reservationID: String?,
                                    replacingHistoryEntryID: UUID? = nil,
                                    insertOnSuccess: Bool = true,
                                    stateAlreadyTranscribing: Bool = false) {
        if !isTranscribing {
            isTranscribing = true
        }
        if !stateAlreadyTranscribing {
            notifyStateChanged()
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
                    self.failedTranscription = nil
                    self.isTranscribing = false
                    self.notifyStateChanged()
                    // Transcript is saved — unless a developer is preserving
                    // WAVs for STT prompt A/B tests, the recording is no longer needed.
                    // (Failed dictations keep theirs for Retry; see the catch.)
                    if !Settings.shared.keepSuccessfulDictationRecordings {
                        try? FileManager.default.removeItem(at: audioURL)
                        VoiceRecorder.shared.clearLastRecording(if: audioURL)
                    }
                    self.schedulePostTranscriptionSideEffects(text: text,
                                                              duration: duration,
                                                              app: app,
                                                              replacingHistoryEntryID: replacingHistoryEntryID,
                                                              insertOnSuccess: insertOnSuccess)
                }
            } catch {
                await MainActor.run {
                    let failureID = DictationHistory.shared.recordFailure(
                        audioURL: audioURL,
                        duration: duration,
                        app: app,
                        error: SensitiveLogRedactor.redact(error.localizedDescription),
                        replacing: replacingHistoryEntryID
                    )
                    if let failureID {
                        self.failedTranscription = FailedTranscription(audioURL: audioURL,
                                                                       duration: duration,
                                                                       app: app,
                                                                       historyEntryID: failureID,
                                                                       insertOnSuccess: insertOnSuccess)
                    } else {
                        self.failedTranscription = nil
                    }
                    self.isTranscribing = false
                    self.notifyStateChanged()
                    if failureID != nil {
                        NotificationCenter.default.post(name: .langFlipDictationTranscriptionFailed, object: nil)
                    }
                    let body = failureID == nil
                        ? "Recording was discarded because local history is off."
                        : "Click Retry on the dictation island."
                    if Settings.shared.dictationNotifications {
                        Notifications.show(title: "Transcription failed", body: body)
                    }
                    AppLog.write("STT failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func schedulePostTranscriptionSideEffects(text: String,
                                                      duration: Double?,
                                                      app: String?,
                                                      replacingHistoryEntryID: UUID?,
                                                      insertOnSuccess: Bool) {
        // Insert as soon as the transcript is ready — on the next runloop tick so
        // the transcribing→done flip commits its first frame before the (tiny)
        // synchronous paste, without a perceptible delay.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if insertOnSuccess {
                self.insert(text, duration: duration, app: app, replacingHistoryEntryID: replacingHistoryEntryID)
            } else if let replacingHistoryEntryID {
                DictationHistory.shared.replaceFailed(id: replacingHistoryEntryID, with: text, duration: duration, app: app)
                Sound.playFlip()
            }
        }
    }

    /// Discard an in-progress recording without transcribing or inserting.
    /// Backs the island's ✕ (cancel) control.
    func cancel() {
        guard isRecording else { return }
        VoiceRecorder.shared.stop()
        discardPendingCancelledRecording()
        pendingCancelledRecordingURL = VoiceRecorder.shared.lastRecordingURL
        sttReservationTask?.cancel()
        sttReservationTask = nil
        sttReservation = nil
        isRecording = false
        mode = nil
        recordingStartedAt = nil
        recordingApp = nil
        failedTranscription = nil
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
            guard SupabaseBackendAuth.hasStoredSession else { return }
            ConnectionWarmer.warm(BackendConfig.functionsBaseURL, label: "STT")
        } else if let url = URL(string: Settings.shared.cloudSTTBaseURL) {
            ConnectionWarmer.warm(url, label: "STT")
        }
    }

    private func prepareSTTReservation() {
        sttReservationTask?.cancel()
        sttReservation = nil
        guard Settings.shared.aiMode == .backend,
              SupabaseBackendAuth.hasStoredSession
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
            guard SupabaseBackendAuth.hasStoredSession else {
                throw CloudTranscriptionError.notSignedIn
            }
            let upload = try STTAudioUploadPreparer.prepareBackendUpload(from: audioURL)
            defer { upload.cleanup() }
            // Developers (Advanced) can pin the STT model for their account;
            // everyone else sends nil and gets the backend's server default.
            let modelOverride = Self.backendSTTModelOverride()
            let modelLog = modelOverride ?? "server-default"
            NetworkLatency.log.info("STT model=\(modelLog, privacy: .public)")
            AppLog.write("STT model=\(modelLog)")

            let request = BackendTranscribeRequest(audio: upload.data,
                                                   filename: upload.filename,
                                                   language: nil,
                                                   prompt: STTTranscriptionPrompt.current(),
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
                                             prompt: STTTranscriptionPrompt.current(),
                                             model: modelOverride)
                )
            }
            return result.text
        }
        return try await CloudTranscriber.transcribe(audioURL: audioURL)
    }

    private static func backendSTTModelOverride() -> String? {
        Settings.shared.backendSTTModelOverride
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

    private func insert(_ text: String, duration: Double? = nil, app: String? = nil, replacingHistoryEntryID: UUID? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if Settings.shared.dictationNotifications {
                Notifications.show(title: "Dictation", body: "No speech was recognized.")
            }
            return
        }

        // Expand any snippet triggers automatically before inserting.
        let cleaned = SnippetStore.shared.expand(trimmed)
        let beforeContext = FocusedTextReader.current()
        let appBundleID = AppContext.frontmostBundleID()

        let shouldRestoreClipboard = beforeContext != nil
        TransientPasteboard.pasteString(cleaned, restoreOriginalClipboard: shouldRestoreClipboard) {
            postCommandV()
        }
        Sound.playFlip()
        DictationCorrectionLearner.shared.recordInsertion(
            text: cleaned,
            beforeContext: beforeContext,
            appBundleID: appBundleID
        )
        if let replacingHistoryEntryID {
            DictationHistory.shared.replaceFailed(id: replacingHistoryEntryID, with: cleaned, duration: duration, app: app)
        } else {
            DictationHistory.shared.add(cleaned, duration: duration, app: app)
        }
        // The text appears at the cursor and the sound confirms success; no
        // system banner is needed for successful dictation.
    }

    /// Put `text` on the clipboard and paste it into the frontmost app. Used by
    /// the menubar's "Paste last transcript" — unlike `insert`, it doesn't log
    /// to history or play feedback (it's re-pasting something already captured).
    func pasteText(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let shouldRestoreClipboard = FocusedTextReader.current() != nil
        TransientPasteboard.pasteString(cleaned, restoreOriginalClipboard: shouldRestoreClipboard) {
            postCommandV()
        }
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
