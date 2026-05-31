import Foundation

/// AIAssistant talking to any **OpenAI-compatible** chat-completions
/// endpoint. Single backend covers:
///   - OpenAI direct       (https://api.openai.com/v1)
///   - OpenRouter          (https://openrouter.ai/api/v1) — single
///                          key, hundreds of models including
///                          gpt-oss-120b, claude-3.7, gemini-2.5
///   - Together AI         (https://api.together.xyz/v1)
///   - Fireworks           (https://api.fireworks.ai/inference/v1)
///   - Groq                (https://api.groq.com/openai/v1)
///   - Local LM Studio     (http://localhost:1234/v1)
///
/// User picks a base URL + paste their key, and types whatever model
/// name the provider exposes. We don't validate names client-side —
/// the upstream returns "model not found" cleanly enough.
final class OpenAIAssistant: AIAssistant {

    /// Hard wall-clock timeout per request. Cloud round-trip is
    /// typically 0.3-2 s for nano models, occasionally 5-10 s for
    /// reasoning models. We set the cap at 25 s to cover the slowest
    /// reasoning calls without ever hanging the EventTap forever.
    private static let inferenceTimeout: TimeInterval = 25.0

    /// User's chosen API key. Captured at init — AIAssistantManager
    /// rebuilds us when Settings change, so a stale key here means
    /// the manager hasn't noticed the rotation yet (one extra failed
    /// call, then `current` rebuilds).
    private let apiKey: String
    private let model: String
    private let baseURL: URL

    /// Whether to send `Authorization: Bearer …`. All known
    /// OpenAI-compatible endpoints use Bearer auth, but we may want
    /// to skip it for unauthenticated localhost endpoints.
    private let authorize: Bool

    init(apiKey: String, model: String, baseURLString: String) {
        self.apiKey = apiKey
        self.model  = model
        self.baseURL = URL(string: baseURLString) ?? URL(string: "https://api.openai.com/v1")!
        self.authorize = !apiKey.isEmpty
    }

    /// "Ready" if we have any key at all and the base URL parses.
    /// We don't probe the server — that would add a 200 ms blocker
    /// to every keystroke gate. A failed call lands as `.failed` /
    /// `.unknown` and the EventTap suppresses cleanly.
    var isReady: Bool { !apiKey.isEmpty }

    // MARK: - AIAssistant methods

    func review(candidateFlip: AICandidate, completion: @escaping (AIDecision) -> Void) {
        let user = """
        Keyboard-layout fix arbiter. The user typed "\(candidateFlip.originalWord)" and the rules engine wants to flip it to "\(candidateFlip.proposedFlip)".
        Context: \(candidateFlip.context.isEmpty ? "(none)" : candidateFlip.context)
        Reply with exactly one word: FLIP, KEEP, or UNKNOWN.
        """
        chatCompletion(
            messages: [
                ["role": "system", "content": "You are a terse keyboard-layout arbiter. Output one word."],
                ["role": "user",   "content": user],
            ],
            options: ["temperature": 0, "max_tokens": 4]
        ) { result in
            switch result {
            case .success(let raw):
                let upper = raw.uppercased()
                if upper.contains("FLIP") { completion(.flip(target: candidateFlip.targetLayout)); return }
                if upper.contains("KEEP") { completion(.dontFlip); return }
                completion(.unknown)
            case .failure:
                completion(.unknown)
            }
        }
    }

    func rewriteSentence(_ input: AIRewriteRequest, completion: @escaping (AIRewriteResult) -> Void) {
        let lang = input.preferredLayout?.displayName ?? "input language"
        chatCompletion(
            messages: [
                ["role": "system", "content": Self.rewriteSystemPrompt(language: lang, allowLayoutRepair: false)],
                ["role": "user",   "content": input.text],
            ],
            options: Self.fastTextEditOptions(inputCharacterCount: input.text.count, cap: 256)
        ) { result in
            switch result {
            case .success(let raw):
                let cleaned = Self.unwrapModelOutput(raw)
                if cleaned.isEmpty || cleaned == input.text {
                    completion(.unchanged)
                } else {
                    completion(.rewritten(cleaned))
                }
            case .failure(let reason):
                completion(.failed(reason: reason))
            }
        }
    }

    func fixSelection(_ input: AIFixRequest, completion: @escaping (AIFixResult) -> Void) {
        let lang = input.activeLayout?.displayName ?? "user's language"
        chatCompletion(
            messages: [
                ["role": "system", "content": Self.rewriteSystemPrompt(language: lang, allowLayoutRepair: true)],
                ["role": "user",   "content": input.text],
            ],
            options: Self.fastTextEditOptions(inputCharacterCount: input.text.count, cap: 512)
        ) { result in
            switch result {
            case .success(let raw):
                let cleaned = Self.unwrapModelOutput(raw)
                if cleaned.isEmpty {
                    completion(.failed(reason: "empty response"))
                } else if cleaned == input.text {
                    completion(.unchanged)
                } else {
                    completion(.fixed(cleaned))
                }
            case .failure(let reason):
                completion(.failed(reason: reason))
            }
        }
    }

    func translateSelection(_ input: AITranslateRequest, completion: @escaping (AITranslateResult) -> Void) {
        let target = input.target.displayName
        chatCompletion(
            messages: [
                ["role": "system", "content": "Translate the user's text into \(target). Do not answer, explain, or continue the text. Preserve meaning and formatting. Output ONLY the translation, no quotes."],
                ["role": "user",   "content": input.text],
            ],
            options: ["temperature": 0.2, "max_tokens": 1024]
        ) { result in
            switch result {
            case .success(let raw):
                let cleaned = Self.unwrapModelOutput(raw)
                if cleaned.isEmpty {
                    completion(.failed(reason: "empty response"))
                } else {
                    completion(.translated(cleaned))
                }
            case .failure(let reason):
                completion(.failed(reason: reason))
            }
        }
    }

    func extractTextFromImage(_ input: AIOcrRequest, completion: @escaping (AIOcrResult) -> Void) {
        let visionModel = Settings.shared.cloudOCRModel
        let dataURL = "data:image/png;base64,\(input.imageBase64)"
        chatCompletion(
            modelOverride: visionModel,
            messages: [
                [
                    "role": "system",
                    "content": "You are an OCR engine. Output only the text visible in the image. Preserve line breaks. No commentary."
                ],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": "Read the text in this screenshot. Output only the text exactly as it appears."
                        ],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": dataURL
                            ]
                        ]
                    ]
                ]
            ],
            options: ["temperature": 0, "max_tokens": 512]
        ) { result in
            switch result {
            case .success(let raw):
                let cleaned = Self.unwrapModelOutput(raw)
                if cleaned.isEmpty {
                    completion(.failed(reason: "model returned no text"))
                } else {
                    completion(.extracted(cleaned))
                }
            case .failure(let reason):
                completion(.failed(reason: reason))
            }
        }
    }

    // MARK: - HTTP

    private static func rewriteSystemPrompt(language: String, allowLayoutRepair: Bool) -> String {
        let layoutRule = allowLayoutRepair
            ? "If part of the text is obvious wrong-keyboard-layout gibberish, repair it into \(language)."
            : "Do not translate or change the language. Treat the current keyboard layout as the intended output language: \(language)."
        return """
        You edit user text inside a macOS typing assistant.
        Current keyboard layout / intended output language: \(language).
        \(layoutRule)
        Fix only typos, grammar, punctuation, capitalization, and small wording issues.
        Preserve meaning, tone, names, code, URLs, markdown, line breaks, and formatting.
        Output ONLY the corrected text. No quotes, no explanation.
        """
    }

    private static func fastTextEditOptions(inputCharacterCount: Int, cap: Int) -> [String: Any] {
        let estimatedOutputTokens = max(64, min(cap, (inputCharacterCount / 2) + 64))
        return [
            "temperature": 0,
            "max_tokens": estimatedOutputTokens,
        ]
    }

    private enum InferenceResult {
        case success(String)
        case failure(String)
    }

    /// One-shot POST to <baseURL>/chat/completions. Returns the
    /// content of choices[0].message.content, or a short failure
    /// reason. Errors include network failures, non-2xx, malformed
    /// JSON, refusal-style empty content.
    private func chatCompletion(
        modelOverride: String? = nil,
        messages: [[String: Any]],
        options: [String: Any],
        completion: @escaping (InferenceResult) -> Void
    ) {
        let endpoint = baseURL.appendingPathComponent("chat/completions")

        var body: [String: Any] = [
            "model":    modelOverride?.isEmpty == false ? modelOverride! : model,
            "messages": messages,
            "stream":   false,
        ]
        for (k, v) in options { body[k] = v }

        let usesOpenRouter = baseURL.host?.localizedCaseInsensitiveContains("openrouter.ai") == true
        if usesOpenRouter {
            if body["provider"] == nil {
                body["provider"] = ["sort": "latency"]
            }
            if body["reasoning"] == nil {
                body["reasoning"] = ["exclude": true]
            }
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = Self.inferenceTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authorize {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if usesOpenRouter {
            req.setValue("LangFlip", forHTTPHeaderField: "X-Title")
            req.setValue("https://github.com/MikeKorotych/lang-flip", forHTTPHeaderField: "HTTP-Referer")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                completion(.failure("network: \(error.localizedDescription)"))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure("no response"))
                return
            }
            guard let data else {
                completion(.failure("HTTP \(http.statusCode), empty body"))
                return
            }
            // Try to parse JSON whether it's an error or success.
            let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if !(200..<300).contains(http.statusCode) {
                if let err = parsed?["error"] as? [String: Any],
                   let msg = err["message"] as? String {
                    completion(.failure("HTTP \(http.statusCode): \(msg)"))
                } else {
                    completion(.failure("HTTP \(http.statusCode)"))
                }
                return
            }
            guard let parsed,
                  let choices = parsed["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                completion(.failure("unexpected response shape"))
                return
            }
            completion(.success(content))
        }.resume()
    }

    /// Strip code fences and surrounding quotes — same logic as the
    /// Ollama path. OpenAI/etc occasionally wrap answers in ```text
    /// blocks despite "no quotes" instructions; we don't want literal
    /// backticks landing in the user's document.
    private static func unwrapModelOutput(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = String(s.dropFirst(3))
            if let end = s.range(of: "```") {
                s = String(s[..<end.lowerBound])
            }
            if let nl = s.firstIndex(of: "\n"), s[..<nl].count <= 12 {
                s = String(s[s.index(after: nl)...])
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let pairs: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}"), ("\u{00AB}", "\u{00BB}")
        ]
        for (l, r) in pairs {
            if s.count >= 2, s.first == l, s.last == r {
                s = String(s.dropFirst().dropLast())
                s = s.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return s
    }
}
