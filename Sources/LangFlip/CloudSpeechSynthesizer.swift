import AppKit
import Foundation

/// OpenAI-compatible cloud text-to-speech backend.
///
/// Default endpoint is OpenRouter's `/api/v1/audio/speech`, but this
/// intentionally stays generic: users can point it at OpenAI direct or
/// any provider that implements the Audio Speech API shape.
final class CloudSpeechSynthesizer {
    static let shared = CloudSpeechSynthesizer()

    private var synthesisTask: Task<Void, Never>?
    private var playbackProcess: Process?
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
        synthesisTask != nil || playbackProcess?.isRunning == true
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
                let url = try await generate(text: clean)
                await MainActor.run {
                    self.setBuffering(false)   // audio ready → spinner off, playback starts
                    self.play(url)
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
            guard SupabaseBackendAuth.shared.isSignedIn else {
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

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudSpeechError.noResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudSpeechError.httpStatus(http.statusCode, Self.errorMessage(from: data))
        }
        guard !data.isEmpty else { throw CloudSpeechError.emptyAudio }

        try data.write(to: outputURL, options: .atomic)
        await MainActor.run {
            self.lastOutputURL = outputURL
        }
        return outputURL
    }

    /// TTS via the backend proxy (no provider key). Backend returns audio bytes
    /// (WAV for Gemini / MP3 otherwise); afplay sniffs the format from content.
    private func generateViaBackend(_ text: String) async throws -> URL {
        let instructions = Settings.shared.cloudTTSInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = try await HTTPBackendClient.shared.tts(
            BackendTTSRequest(text: text,
                              voice: Settings.shared.cloudTTSVoice,
                              model: nil,
                              speed: Settings.shared.cloudTTSSpeed,
                              instructions: instructions.isEmpty ? nil : instructions))
        guard !bytes.isEmpty else { throw CloudSpeechError.emptyAudio }
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        let outputURL = Self.outputDirectory.appendingPathComponent("cloud-tts-\(Self.timestamp()).wav")
        try bytes.write(to: outputURL, options: .atomic)
        await MainActor.run { self.lastOutputURL = outputURL }
        return outputURL
    }

    func play(_ url: URL) {
        playbackProcess?.terminate()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [url.path]
        do {
            try process.run()
            playbackProcess = process
        } catch {
            Notifications.show(title: "Audio playback failed", body: error.localizedDescription)
        }
    }

    func stop() {
        setBuffering(false)
        synthesisTask?.cancel()
        synthesisTask = nil
        if playbackProcess?.isRunning == true {
            playbackProcess?.terminate()
        }
        playbackProcess = nil
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func errorMessage(from data: Data) -> String {
        if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = parsed["error"] as? [String: Any] {
                if let message = error["message"] as? String { return message }
                return String(describing: error)
            }
            if let message = parsed["message"] as? String { return message }
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
            return "Invalid TTS base URL: \(value)"
        case .noResponse:
            return "The TTS provider did not return a valid response."
        case .httpStatus(let status, let message):
            return message.isEmpty ? "TTS provider returned HTTP \(status)." : "TTS provider returned HTTP \(status): \(message)"
        case .emptyAudio:
            return "The TTS provider returned an empty audio file."
        }
    }
}
