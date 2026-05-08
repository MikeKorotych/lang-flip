import Foundation

/// AIAssistant backed by a locally-running Ollama daemon
/// (https://ollama.com). Lets users compare any open-weight model
/// (Gemma, Qwen, Llama, …) against Apple Foundation Models without us
/// having to ship a runtime.
///
/// User flow:
///   1. brew install ollama  (or download .app from ollama.com)
///   2. ollama serve  (auto-runs on macOS)
///   3. ollama pull gemma3   (or whatever model they want)
///   4. In LangFlip Preferences → AI: pick "Ollama (local)" + model name
///
/// We hit `POST http://localhost:11434/api/generate` with a non-stream
/// request and parse the single JSON response. Errors (daemon not
/// running, model not pulled, timeout) all map to `.failed` with a
/// short reason string so the EventTap can fall back gracefully.
final class OllamaAssistant: AIAssistant {

    /// Hard wall-clock timeout per inference. Tuned for Gemma-class
    /// open-weight models on Apple Silicon: cold-start can hit 20 s
    /// (load + prompt encode), hot calls are 1-5 s. We give 30 s of
    /// headroom because a one-time delay on the first AI call is much
    /// less annoying than silent failures.
    private static let inferenceTimeout: TimeInterval = 30.0

    /// Daemon endpoint. Hardcoded to localhost for security (the
    /// pipeline assumes everything stays on the user's machine — no
    /// shipping their text to a remote box).
    private static let endpoint = URL(string: "http://localhost:11434/api/generate")!

    /// User-configured model tag (e.g. "gemma3", "qwen2.5:1.5b",
    /// "llama3.2"). Captured at init so a runtime Settings change
    /// doesn't race with an inference call mid-flight; AIAssistantManager
    /// rebuilds us when the mode/model changes.
    private let model: String

    /// Cached availability result so we don't probe the daemon on every
    /// EventTap call. Refreshed lazily.
    private var lastReadyCheck: (timestamp: Date, ready: Bool)?
    private static let readyCacheTTL: TimeInterval = 5.0

    init(model: String) {
        self.model = model
    }

    /// "Ready" means the daemon is reachable AND the configured model
    /// is in its library. We cache the result for `readyCacheTTL` to
    /// avoid blocking the keyDown hot path with a network call.
    var isReady: Bool {
        if let last = lastReadyCheck, Date().timeIntervalSince(last.timestamp) < Self.readyCacheTTL {
            return last.ready
        }
        let ready = probeReady()
        lastReadyCheck = (Date(), ready)
        return ready
    }

    private func probeReady() -> Bool {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.0
        var ready = false
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = obj["models"] as? [[String: Any]] else {
                return
            }
            // Match by exact name OR by name-without-tag (so user can
            // type "gemma3" and we accept "gemma3:latest").
            let installed = models.compactMap { $0["name"] as? String }
            ready = installed.contains { name in
                name == self.model || name.split(separator: ":").first.map(String.init) == self.model
            }
        }.resume()
        // Block briefly. Acceptable because EventTap calls isReady on
        // a non-blocking path (gates feature firing) and our cache TTL
        // stops this from happening more than once per 5s.
        _ = sem.wait(timeout: .now() + 1.5)
        return ready
    }

    // MARK: - AIAssistant methods

    func review(candidateFlip: AICandidate, completion: @escaping (AIDecision) -> Void) {
        let prompt = """
        Keyboard-layout fix arbiter. The user typed "\(candidateFlip.originalWord)" and the rules engine wants to flip it to "\(candidateFlip.proposedFlip)".
        Context: \(candidateFlip.context.isEmpty ? "(none)" : candidateFlip.context)
        Reply with exactly one word: FLIP, KEEP, or UNKNOWN.
        """
        runInference(prompt: prompt, options: ["temperature": 0, "num_predict": 8]) { result in
            switch result {
            case .success(let text):
                let upper = text.uppercased()
                if upper.contains("FLIP")  { completion(.flip(target: candidateFlip.targetLayout)); return }
                if upper.contains("KEEP")  { completion(.dontFlip); return }
                completion(.unknown)
            case .failure:
                completion(.unknown)
            }
        }
    }

    func rewriteSentence(_ input: AIRewriteRequest, completion: @escaping (AIRewriteResult) -> Void) {
        let lang = input.preferredLayout?.displayName ?? "the input language"
        let prompt = """
        Rewrite the following text to fix typos, grammar, and obvious mistakes. Preserve tone and meaning. Output ONLY the corrected text — no explanation, no quotes.

        Language hint: \(lang).
        Text:
        \(input.text)
        """
        runInference(prompt: prompt, options: ["temperature": 0.1]) { result in
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
        let lang = input.activeLayout?.displayName ?? "the user's intended language"
        let prompt = """
        Mac text-fixing utility. The selected text may contain typos, grammar mistakes, wrong-keyboard-layout gibberish, or mid-sentence script flips. Repair everything you can while preserving meaning. Active layout hint: \(lang).
        Output ONLY the corrected text. No explanation, no quotes, no preamble.

        Selected text:
        \(input.text)
        """
        runInference(prompt: prompt, options: ["temperature": 0.2]) { result in
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

    func extractTextFromImage(_ input: AIOcrRequest, completion: @escaping (AIOcrResult) -> Void) {
        let prompt = """
        Extract every piece of visible text from this image. Output ONLY the raw text exactly as it appears, preserving line breaks and reading order. No description, no commentary, no headings, no quotes, no markdown. If the image contains no text at all, output an empty string.
        """
        runInference(
            prompt: prompt,
            options: ["temperature": 0],
            images: [input.imageBase64]
        ) { result in
            switch result {
            case .success(let raw):
                let cleaned = Self.unwrapModelOutput(raw)
                if cleaned.isEmpty {
                    completion(.failed(reason: "model returned no text — image may have none, or model isn't multimodal"))
                } else {
                    completion(.extracted(cleaned))
                }
            case .failure(let reason):
                completion(.failed(reason: reason))
            }
        }
    }

    func translateSelection(_ input: AITranslateRequest, completion: @escaping (AITranslateResult) -> Void) {
        let target = input.target.displayName
        let prompt = """
        Translate the following text into \(target). Auto-detect the source. Produce idiomatic, natural \(target) — not a literal word-for-word rendering. Preserve meaning, tone, and formatting.
        Output ONLY the translation. No explanation, no quotes, no preamble, no source-language echo.

        Text:
        \(input.text)
        """
        runInference(prompt: prompt, options: ["temperature": 0.2]) { result in
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

    // MARK: - HTTP

    private enum InferenceResult {
        case success(String)
        case failure(String)
    }

    /// One-shot Ollama call with hard timeout. `options` are passed
    /// through to the daemon (temperature, num_predict, …) — see
    /// https://github.com/ollama/ollama/blob/main/docs/api.md#parameters.
    /// `images` is an array of base64-encoded image bytes for
    /// multimodal models.
    private func runInference(
        prompt: String,
        options: [String: Any],
        images: [String] = [],
        completion: @escaping (InferenceResult) -> Void
    ) {
        var body: [String: Any] = [
            "model":  model,
            "prompt": prompt,
            "stream": false
        ]
        if !options.isEmpty {
            body["options"] = options
        }
        if !images.isEmpty {
            body["images"] = images
        }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = Self.inferenceTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure("HTTP \(http.statusCode)"))
                return
            }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure("invalid JSON"))
                return
            }
            // Ollama also returns an "error" field for things like
            // "model not found".
            if let err = obj["error"] as? String {
                completion(.failure(err))
                return
            }
            guard let text = obj["response"] as? String else {
                completion(.failure("no response field"))
                return
            }
            completion(.success(text))
        }.resume()
    }

    /// Strip leading/trailing whitespace, surrounding quotes, code
    /// fences. Mirrors FoundationModelsAssistant.unwrapModelOutput so
    /// both backends produce identically-cleaned strings.
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
