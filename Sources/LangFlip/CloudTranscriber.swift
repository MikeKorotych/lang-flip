import Foundation

enum CloudTranscriber {
    static func transcribe(audioURL: URL) async throws -> String {
        guard let apiKey = Settings.shared.openaiAPIKey, !apiKey.isEmpty else {
            throw CloudTranscriptionError.missingAPIKey
        }
        let base = Settings.shared.cloudSTTBaseURL
        guard let baseURL = URL(string: base) else {
            throw CloudTranscriptionError.invalidBaseURL(base)
        }

        let data = try Data(contentsOf: audioURL)
        let format = audioURL.pathExtension.lowercased().isEmpty ? "wav" : audioURL.pathExtension.lowercased()
        let endpoint = baseURL.appendingPathComponent("audio/transcriptions")

        // Local pre-flight cost: reading the WAV + base64-encoding it into JSON.
        // base64 inflates the payload ~33% over a raw multipart upload — worth
        // knowing how much of the STT latency is spent here vs on the network.
        let encodeStart = DispatchTime.now()
        let encoded = data.base64EncodedString()
        NetworkLatency.log.info(
            "STT encode=\(String(format: "%.0f", NetworkLatency.elapsedMs(since: encodeStart)), privacy: .public)ms audio=\(data.count, privacy: .public)B b64=\(encoded.count, privacy: .public)B model=\(Settings.shared.cloudSTTModel, privacy: .public)"
        )

        let body: [String: Any] = [
            "model": Settings.shared.cloudSTTModel,
            "prompt": STTTranscriptionPrompt.current(),
            "input_audio": [
                "data": encoded,
                "format": format,
            ]
        ]

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

        let (responseData, response) = try await URLSession.shared.measuredData(for: request, label: "STT")
        guard let http = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.noResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudTranscriptionError.httpStatus(http.statusCode, errorMessage(from: responseData))
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let text = parsed["text"] as? String
        else {
            throw CloudTranscriptionError.malformedResponse
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CloudTranscriptionError.emptyResult
        }
        return trimmed
    }

    private static func errorMessage(from data: Data) -> String {
        if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = parsed["error"] as? [String: Any] {
                if let message = error["message"] as? String { return SensitiveLogRedactor.redact(message) }
                if let metadata = error["metadata"] as? [String: Any] {
                    if let raw = metadata["raw"] as? String { return SensitiveLogRedactor.redact(raw) }
                    if let providerName = metadata["provider_name"] as? String {
                        return SensitiveLogRedactor.redact("\(providerName): \(metadata)")
                    }
                }
                return SensitiveLogRedactor.redact(String(describing: error))
            }
            if let message = parsed["message"] as? String { return SensitiveLogRedactor.redact(message) }
            if let detail = parsed["detail"] as? String { return SensitiveLogRedactor.redact(detail) }
        }
        let message = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return SensitiveLogRedactor.redact(message)
    }
}

enum CloudTranscriptionError: LocalizedError {
    case missingAPIKey
    case notSignedIn
    case invalidBaseURL(String)
    case noResponse
    case httpStatus(Int, String)
    case malformedResponse
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an OpenRouter or OpenAI API key in Voice settings."
        case .notSignedIn:
            return "Sign in to Sayful Cloud to use cloud dictation (profile menu, top-right)."
        case .invalidBaseURL(let value):
            return "Invalid STT base URL: \(SensitiveLogRedactor.redact(value))"
        case .noResponse:
            return "The transcription provider did not return a valid response."
        case .httpStatus(let status, let message):
            let redacted = SensitiveLogRedactor.redact(message)
            return redacted.isEmpty ? "Transcription provider returned HTTP \(status)." : "Transcription provider returned HTTP \(status): \(redacted)"
        case .malformedResponse:
            return "The transcription provider returned an unexpected response."
        case .emptyResult:
            return "No speech was recognized."
        }
    }
}
