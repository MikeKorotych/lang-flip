import AppKit
import AVFoundation
import Foundation

/// OpenAI-compatible cloud text-to-speech backend.
///
/// Default endpoint is OpenRouter's `/api/v1/audio/speech`, but this
/// intentionally stays generic: users can point it at OpenAI direct or
/// any provider that implements the Audio Speech API shape.
final class CloudSpeechSynthesizer {
    static let shared = CloudSpeechSynthesizer()

    private var synthesisTask: Task<Void, Never>?
    private var pcmPlayback: PCMStreamPlayer?
    private(set) var lastOutputURL: URL?

    /// True while audio is being synthesized (before playback starts). Drives the
    /// dictation island's `.speaking` spinner — the "preparing audio" indicator.
    private(set) var isBuffering = false

    private init() {}

    private func setBuffering(_ value: Bool) {
        guard isBuffering != value else { return }
        isBuffering = value
        NotificationCenter.default.post(name: .langFlipTTSStateChanged, object: nil)
    }

    static var outputDirectory: URL {
        URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/Sayful/TTS", isDirectory: true)
    }

    var isSpeaking: Bool {
        synthesisTask != nil || AudioFilePlayer.shared.isPlaying || pcmPlayback != nil
    }

    @discardableResult
    func speak(_ text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        stop()
        setBuffering(true)

        synthesisTask = Task { [weak self] in
            guard let self else { return }
            do {
                if Settings.shared.aiMode == .backend,
                   Settings.shared.experimentalStreamingCloudTTS,
                   Settings.shared.cloudTTSModel.localizedCaseInsensitiveContains("gemini") {
                    try await self.streamViaBackend(clean)
                    await MainActor.run {
                        self.setBuffering(false)
                        self.synthesisTask = nil
                    }
                } else {
                    let url = try await generate(text: clean)
                    await MainActor.run {
                        self.setBuffering(false)   // audio ready → spinner off, playback starts
                        self.play(url)
                        self.synthesisTask = nil
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.setBuffering(false)
                    self.synthesisTask = nil
                }
            } catch {
                await MainActor.run {
                    self.setBuffering(false)
                    self.synthesisTask = nil
                    Notifications.show(title: "Cloud TTS failed", body: error.localizedDescription)
                }
            }
        }
        return true
    }

    func generate(text: String) async throws -> URL {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw CloudSpeechError.emptyText }

        // Sayful Cloud → backend proxy (no provider key); requires sign-in.
        if Settings.shared.aiMode == .backend {
            guard SupabaseBackendAuth.hasStoredSession else {
                throw CloudSpeechError.notSignedIn
            }
            return try await generateViaBackend(clean)
        }

        guard let apiKey = Settings.shared.openaiAPIKey, !apiKey.isEmpty else {
            throw CloudSpeechError.missingAPIKey
        }

        let base = Settings.shared.cloudTTSBaseURL
        guard let baseURL = URL(string: base) else { throw CloudSpeechError.invalidBaseURL(base) }
        let endpoint = baseURL.appendingPathComponent("audio/speech")

        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        let outputURL = Self.outputDirectory
            .appendingPathComponent("cloud-tts-\(Self.timestamp()).mp3")

        var body: [String: Any] = [
            "model": Settings.shared.cloudTTSModel,
            "input": clean,
            "voice": Settings.shared.cloudTTSVoice,
            "response_format": "mp3",
            "speed": Settings.shared.cloudTTSSpeed,
        ]

        let instructions = Settings.shared.cloudTTSInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            if baseURL.host?.localizedCaseInsensitiveContains("openrouter.ai") == true,
               Settings.shared.cloudTTSModel.hasPrefix("openai/") {
                body["provider"] = [
                    "options": [
                        "openai": [
                            "instructions": instructions,
                        ],
                    ],
                ]
            } else {
                body["instructions"] = instructions
            }
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if baseURL.host?.localizedCaseInsensitiveContains("openrouter.ai") == true {
            request.setValue("Sayful", forHTTPHeaderField: "X-Title")
            request.setValue("https://github.com/MikeKorotych/lang-flip", forHTTPHeaderField: "HTTP-Referer")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.measuredData(for: request, label: "TTS")
        guard let http = response as? HTTPURLResponse else {
            throw CloudSpeechError.noResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudSpeechError.httpStatus(http.statusCode, Self.errorMessage(from: data))
        }
        guard !data.isEmpty else { throw CloudSpeechError.emptyAudio }

        // Disk write sits between "audio downloaded" and "afplay can start",
        // so it counts toward perceived time-to-first-audio.
        let writeStart = DispatchTime.now()
        try data.write(to: outputURL, options: .atomic)
        NetworkLatency.log.info(
            "TTS write=\(String(format: "%.0f", NetworkLatency.elapsedMs(since: writeStart)), privacy: .public)ms audio=\(data.count, privacy: .public)B model=\(Settings.shared.cloudTTSModel, privacy: .public)"
        )
        await MainActor.run {
            self.lastOutputURL = outputURL
            TTSHistory.shared.add(text: clean,
                                  audioURL: outputURL,
                                  model: Settings.shared.cloudTTSModel,
                                  voice: Settings.shared.cloudTTSVoice)
        }
        return outputURL
    }

    /// TTS via the backend proxy (no provider key). Backend returns audio bytes
    /// (WAV for Gemini / MP3 otherwise); afplay sniffs the format from content.
    private func generateViaBackend(_ text: String) async throws -> URL {
        let instructions = Settings.shared.cloudTTSInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = BackendModelPolicy.ttsModelOverride()
        let modelLog = BackendModelPolicy.displayName(model)
        let bytes = try await HTTPBackendClient.shared.tts(
            BackendTTSRequest(text: text,
                              voice: Settings.shared.cloudTTSVoice,
                              model: model,
                              speed: Settings.shared.cloudTTSSpeed,
                              instructions: instructions.isEmpty ? nil : instructions))
        guard !bytes.isEmpty else { throw CloudSpeechError.emptyAudio }
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        let outputURL = Self.outputDirectory.appendingPathComponent("cloud-tts-\(Self.timestamp()).wav")
        let writeStart = DispatchTime.now()
        try bytes.write(to: outputURL, options: .atomic)
        NetworkLatency.log.info(
            "TTS write=\(String(format: "%.0f", NetworkLatency.elapsedMs(since: writeStart)), privacy: .public)ms audio=\(bytes.count, privacy: .public)B model=\(modelLog, privacy: .public)"
        )
        await MainActor.run {
            self.lastOutputURL = outputURL
            TTSHistory.shared.add(text: text,
                                  audioURL: outputURL,
                                  model: modelLog,
                                  voice: Settings.shared.cloudTTSVoice)
        }
        return outputURL
    }

    /// Experimental Sayful Cloud streaming path. The backend returns Gemini raw
    /// s16le PCM chunks; we feed them to AVAudioEngine as they arrive.
    private func streamViaBackend(_ text: String) async throws {
        let instructions = Settings.shared.cloudTTSInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = BackendModelPolicy.ttsModelOverride()
        let modelLog = BackendModelPolicy.displayName(model)
        let started = DispatchTime.now()
        var player: PCMStreamPlayer?
        var firstAudioAt: Date?

        let info = try await HTTPBackendClient.shared.ttsPCMStream(
            BackendTTSRequest(text: text,
                              voice: Settings.shared.cloudTTSVoice,
                              model: model,
                              speed: Settings.shared.cloudTTSSpeed,
                              instructions: instructions.isEmpty ? nil : instructions)
        ) { info in
            let p = try PCMStreamPlayer(sampleRate: info.sampleRate, channels: info.channels)
            try p.start()
            player = p
            pcmPlayback = p
        } onChunk: { chunk in
            guard let player else { return }
            if firstAudioAt == nil {
                firstAudioAt = Date()
                NetworkLatency.log.info(
                    "TTS stream firstAudio=\(String(format: "%.0f", NetworkLatency.elapsedMs(since: started)), privacy: .public)ms chunk=\(chunk.count, privacy: .public)B model=\(modelLog, privacy: .public)"
                )
                Task { @MainActor in self.setBuffering(false) }
            }
            try player.append(chunk)
        }

        guard let player, info.bytes > 0 else { throw CloudSpeechError.emptyAudio }
        let seconds = Double(info.bytes) / Double(max(info.sampleRate, 1) * max(info.channels, 1) * 2)
        let elapsed = firstAudioAt.map { Date().timeIntervalSince($0) } ?? 0
        let remaining = max(0, seconds - elapsed + 0.25)
        if remaining > 0 {
            try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        player.stop()
        if pcmPlayback === player { pcmPlayback = nil }
        NetworkLatency.log.info(
            "TTS stream total=\(String(format: "%.0f", NetworkLatency.elapsedMs(since: started)), privacy: .public)ms audio=\(info.bytes, privacy: .public)B rate=\(info.sampleRate, privacy: .public) channels=\(info.channels, privacy: .public)"
        )
    }

    func play(_ url: URL) {
        lastOutputURL = url
        _ = AudioFilePlayer.shared.play(url, deleteOnStop: !LocalContentPrivacy.retainsLocalContentHistory)
    }

    func stop() {
        setBuffering(false)
        synthesisTask?.cancel()
        synthesisTask = nil
        AudioFilePlayer.shared.stop()
        pcmPlayback?.stop()
        pcmPlayback = nil
        NotificationCenter.default.post(name: .langFlipTTSStateChanged, object: nil)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func errorMessage(from data: Data) -> String {
        if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = parsed["error"] as? [String: Any] {
                if let message = error["message"] as? String { return SensitiveLogRedactor.redact(message) }
                return SensitiveLogRedactor.redact(String(describing: error))
            }
            if let message = parsed["message"] as? String { return SensitiveLogRedactor.redact(message) }
        }
        let message = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return SensitiveLogRedactor.redact(message)
    }
}

private final class PCMStreamPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let bytesPerFrame: Int
    private var pending = Data()

    init(sampleRate: Int, channels: Int) throws {
        let channelCount = AVAudioChannelCount(max(channels, 1))
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(max(sampleRate, 1)),
            channels: channelCount,
            interleaved: true
        ) else {
            throw CloudSpeechError.noResponse
        }
        self.format = format
        self.bytesPerFrame = Int(channelCount) * MemoryLayout<Int16>.size
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func start() throws {
        try engine.start()
        player.play()
    }

    func append(_ data: Data) throws {
        pending.append(data)
        let usable = pending.count - (pending.count % bytesPerFrame)
        guard usable > 0 else { return }
        let audio = Data(pending.prefix(usable))
        pending.removeFirst(usable)
        try schedule(audio)
    }

    func stop() {
        player.stop()
        engine.stop()
        pending.removeAll()
    }

    private func schedule(_ data: Data) throws {
        let frames = AVAudioFrameCount(data.count / bytesPerFrame)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return
        }
        buffer.frameLength = frames
        data.withUnsafeBytes { src in
            guard let base = src.baseAddress,
                  let dst = buffer.mutableAudioBufferList.pointee.mBuffers.mData else { return }
            memcpy(dst, base, data.count)
            buffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = UInt32(data.count)
        }
        player.scheduleBuffer(buffer)
    }
}

enum CloudSpeechError: LocalizedError {
    case emptyText
    case notSignedIn
    case missingAPIKey
    case invalidBaseURL(String)
    case noResponse
    case httpStatus(Int, String)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "No text to read."
        case .notSignedIn:
            return "Sign in to Sayful Cloud to use text-to-speech (profile menu, top-right)."
        case .missingAPIKey:
            return "Add an OpenRouter or OpenAI API key in Voice settings."
        case .invalidBaseURL(let value):
            return "Invalid TTS base URL: \(SensitiveLogRedactor.redact(value))"
        case .noResponse:
            return "The TTS provider did not return a valid response."
        case .httpStatus(let status, let message):
            let redacted = SensitiveLogRedactor.redact(message)
            return redacted.isEmpty ? "TTS provider returned HTTP \(status)." : "TTS provider returned HTTP \(status): \(redacted)"
        case .emptyAudio:
            return "The TTS provider returned an empty audio file."
        }
    }
}
