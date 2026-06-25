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
/// We hit `POST http://127.0.0.1:11434/api/generate` with a non-stream
/// request and parse the single JSON response. Errors (daemon not
/// running, model not pulled, timeout) all map to `.failed` with a
/// short reason string so the EventTap can fall back gracefully.
final class OllamaAssistant: AIAssistant {

    /// Hard wall-clock timeout per inference. Tuned for Gemma-class
    /// open-weight models on Apple Silicon: cold-start can hit 20-30 s
    /// for multimodal calls (load + image prompt encode), hot text calls
    /// are usually 1-5 s. We give 45 s of headroom because a one-time
    /// delay on the first AI call is much less annoying than a silent
    /// failure right after the user selects a screen region.
    private static let inferenceTimeout: TimeInterval = 45.0

    /// Daemon endpoint. Hardcoded to loopback for security (the
    /// pipeline assumes everything stays on the user's machine — no
    /// shipping their text to a remote box). Use 127.0.0.1 instead of
    /// localhost so URLSession never tries ::1 when Ollama only bound
    /// IPv4.
    private static let endpoint = URL(string: "http://127.0.0.1:11434/api/generate")!

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
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return false }
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
        runInference(prompt: prompt, options: ["temperature": 0, "num_predict": 8, "num_ctx": 1024]) { result in
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
        let lang = input.preferredLayout?.displayName ?? "input language"
        let system = Self.rewriteSystemPrompt(language: lang, allowLayoutRepair: false)
        runInference(
            system: system,
            prompt: input.text,
            options: ["temperature": 0.1, "num_ctx": 2048, "num_predict": 256]
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
        let system = Self.rewriteSystemPrompt(language: lang, allowLayoutRepair: true)
        runInference(
            system: system,
            prompt: input.text,
            options: ["temperature": 0.1, "num_ctx": 2048, "num_predict": 256]
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

    func extractTextFromImage(_ input: AIOcrRequest, completion: @escaping (AIOcrResult) -> Void) {
        let prompt = "Read the text in the image. Output ONLY the text, preserving line breaks. No commentary."
        runInference(
            prompt: prompt,
            options: ["temperature": 0, "num_ctx": 2048, "num_predict": 256],
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
        let prompt = "Translate the user's text into \(target). Do not answer, explain, or continue the text. Preserve meaning and formatting. Output ONLY the translation.\n\(input.text)"
        runInference(
            prompt: prompt,
            options: ["temperature": 0.2, "num_ctx": 4096, "num_predict": 1024]
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

    func warmUp() {
        guard isReady else { return }
        let system = Self.rewriteSystemPrompt(language: "input language", allowLayoutRepair: true)
        runInference(
            system: system,
            prompt: "I dont know why this app works so well but it realy helps me every day",
            options: ["temperature": 0.1, "num_ctx": 1024, "num_predict": 64]
        ) { result in
            switch result {
            case .success:
                AppLog.write("ollama text warm-up completed model=\(self.model)")
            case .failure(let reason):
                AppLog.write("ollama text warm-up failed model=\(self.model): \(reason)")
            }
            self.warmUpVisionIfSupported()
        }
    }

    private func warmUpVisionIfSupported() {
        guard supportsVisionWarmUp else { return }
        runInference(
            prompt: "Look at the image and reply with exactly: OK",
            options: ["temperature": 0, "num_ctx": 1024, "num_predict": 8],
            images: [Self.warmUpImageBase64]
        ) { result in
            switch result {
            case .success:
                AppLog.write("ollama vision warm-up completed model=\(self.model)")
            case .failure(let reason):
                AppLog.write("ollama vision warm-up failed model=\(self.model): \(reason)")
            }
        }
    }

    private var supportsVisionWarmUp: Bool {
        let lower = model.lowercased()
        return lower.contains("qwen3.5") ||
               lower.contains("vision") ||
               lower.contains("-vl") ||
               lower.contains("llava") ||
               lower.contains("gemma3")
    }

    /// Small valid PNG. It is intentionally plain because the goal is only
    /// to make Ollama load the multimodal path before the first real OCR.
    private static let warmUpImageBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAEAAAAAgCAIAAAAt/+nTAAAAPklEQVR4nO3PMQ0AMAzAsPInvYLYYVWKESTzjhsd8KsBrQGtAa0BrQGtAa0BrQGtAa0BrQGtAa0BrQGtAW0BfqHpWg1AJrYAAAAASUVORK5CYII="

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
    ///
    /// We always pass `keep_alive: "30m"` so the model stays resident
    /// in VRAM between calls. Default Ollama keep-alive is 5 minutes —
    /// fine for chat, but too short for sporadic typing where users
    /// might go 6-10 min between sentences and pay the full cold-load
    /// cost again. 30 min is a sweet spot: model evicts when truly idle
    /// but stays warm for typical typing sessions.
    private func runInference(
        system: String? = nil,
        prompt: String,
        options: [String: Any],
        images: [String] = [],
        completion: @escaping (InferenceResult) -> Void
    ) {
        var body: [String: Any] = [
            "model":      model,
            "prompt":     prompt,
            "stream":     false,
            // Thinking-capable models such as Qwen 3 / 3.5 enable a
            // separate reasoning trace by default in Ollama's API.
            // LangFlip needs fast action text, so keep local calls in
            // direct-answer mode.
            "think":      false,
            "keep_alive": "30m"
        ]
        if let system, !system.isEmpty {
            body["system"] = system
        }
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

        let started = Date()
        AppLog.write("ollama inference start model=\(model) promptLen=\(prompt.count) images=\(images.count)")
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                AppLog.write("ollama inference failed after \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(error.localizedDescription)")
                completion(.failure("network: \(error.localizedDescription)"))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                AppLog.write("ollama inference failed after \(String(format: "%.1f", Date().timeIntervalSince(started)))s: no response")
                completion(.failure("no response"))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                AppLog.write("ollama inference failed after \(String(format: "%.1f", Date().timeIntervalSince(started)))s: HTTP \(http.statusCode)")
                completion(.failure("HTTP \(http.statusCode)"))
                return
            }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                AppLog.write("ollama inference failed after \(String(format: "%.1f", Date().timeIntervalSince(started)))s: invalid JSON")
                completion(.failure("invalid JSON"))
                return
            }
            // Ollama also returns an "error" field for things like
            // "model not found".
            if let err = obj["error"] as? String {
                AppLog.write("ollama inference failed after \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(err)")
                completion(.failure(err))
                return
            }
            guard let text = obj["response"] as? String else {
                AppLog.write("ollama inference failed after \(String(format: "%.1f", Date().timeIntervalSince(started)))s: no response field")
                completion(.failure("no response field"))
                return
            }
            AppLog.write("ollama inference success after \(String(format: "%.1f", Date().timeIntervalSince(started)))s outputLen=\(text.count)")
            completion(.success(text))
        }.resume()
    }

    private static func rewriteSystemPrompt(language: String, allowLayoutRepair: Bool) -> String {
        let layoutRule = allowLayoutRepair
            ? "If part of the text is obvious wrong-keyboard-layout gibberish, repair it into \(language)."
            : "Do not translate or change the language. Treat the current keyboard layout as the intended output language: \(language)."
        return """
        You edit user text inside a macOS typing assistant.
        Current keyboard layout / intended output language: \(language).
        \(layoutRule)
        You are a typo-correction engine for fast typed text.
        Primary goal: fix keyboard typos, misspellings, wrong-keyboard-layout
        artifacts, punctuation, capitalization, and spacing with the smallest
        possible edit.
        Preserve the author's sentence, wording, tone, language, slang,
        loanwords, authenticity, names, code, URLs, markdown, line breaks, and
        formatting.
        Do not rewrite for style. Do not improve the text beyond correcting it.
        Do not add new concepts. Do not expand one misspelled word into a phrase.
        For each misspelled word, choose the nearest plausible intended word
        from the same language and context. If a word is ambiguous, choose the
        minimal correction that changes the fewest letters and keeps the
        sentence natural.
        Change a non-typo word only when it clearly does not fit the sentence
        meaning and the intended replacement is strongly implied by nearby
        words. If a slang or borrowed word is understandable and preserves the
        author's voice, keep it. Do not normalize or respell borrowed/
        transliterated words such as "полишинг", "полішинг", "апдейт",
        "фича", or "фіча" only to make them sound more native.
        Capitalization fixes are expected and are not considered rewriting:
        start complete sentences and list items with a capital letter unless the
        item intentionally starts with code, a URL, a username, or a brand style.
        When the text clearly enumerates multiple items, format that part as a
        clean numbered or bulleted list.
        Do not over-punctuate. Avoid adding a comma after ordinary opening time
        words such as "сегодня", "сьогодні", or "today" unless grammar requires
        it. Never write "Сегодня, я" or "Сьогодні, я"; write "Сегодня я" or
        "Сьогодні я".
        When a verb of speech introduces direct words (for example "сказать",
        "сказав", "said", "told"), use a colon and quotation marks for the
        spoken phrase if the boundary is clear.
        For a neutral greeting at the beginning of a sentence, prefer a comma
        over a period or exclamation mark unless the input clearly implies
        stronger emotion.
        Do not add emotional punctuation unless the input already implies it.
        Output ONLY the corrected text. No quotes, no explanation.
        """
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
