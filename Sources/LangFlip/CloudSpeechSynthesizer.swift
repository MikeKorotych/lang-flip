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

    private init() {}

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

        synthesisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await generate(text: clean)
                await MainActor.run {
                    self.play(url)
                    self.synthesisTask = nil
                }
            } catch {
                await MainActor.run {
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
    case missingAPIKey
    case invalidBaseURL(String)
    case noResponse
    case httpStatus(Int, String)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "No text to read."
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
