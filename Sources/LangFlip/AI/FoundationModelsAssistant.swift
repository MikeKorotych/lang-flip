import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// AI assistant backed by macOS 26+ Apple Foundation Models. Uses the
/// system-shared on-device LM — no download, no extra disk space, no
/// telemetry. Falls back to "no opinion" when:
///   - the host OS is older than macOS 26 (compile-time guarded)
///   - Apple Intelligence is disabled in System Settings
///   - the model assets aren't installed yet
///   - inference fails for any reason on the hot path
///
/// All inference happens off the main thread via Swift concurrency. The
/// completion handler is called on an arbitrary queue; callers that need
/// main-thread delivery should hop themselves.
@available(macOS 26.0, *)
final class FoundationModelsAssistant: AIAssistant {

    /// Hard timeout for an individual inference call. We don't want a
    /// stuck model to hold up the EventTap pipeline indefinitely.
    private static let inferenceTimeout: TimeInterval = 1.5

    private let model = SystemLanguageModel.default

    var isReady: Bool {
        switch model.availability {
        case .available: return true
        default:         return false
        }
    }

    func review(candidateFlip: AICandidate, completion: @escaping (AIDecision) -> Void) {
        guard isReady else {
            completion(.unknown)
            return
        }
        let prompt = Self.buildReviewPrompt(candidate: candidateFlip)
        runInference(prompt: prompt) { result in
            completion(Self.parseReview(rawText: result, target: candidateFlip.targetLayout))
        }
    }

    func rewriteSentence(_ input: AIRewriteRequest, completion: @escaping (AIRewriteResult) -> Void) {
        guard isReady else {
            completion(.unsupported)
            return
        }
        let prompt = Self.buildRewritePrompt(input: input)
        runInference(prompt: prompt) { result in
            switch result {
            case .none:
                completion(.failed(reason: "model unavailable"))
            case .some(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed == input.text {
                    completion(.unchanged)
                } else {
                    completion(.rewritten(trimmed))
                }
            }
        }
    }

    func fixSelection(_ input: AIFixRequest, completion: @escaping (AIFixResult) -> Void) {
        guard isReady else {
            completion(.unsupported)
            return
        }
        let prompt = Self.buildFixSelectionPrompt(input: input)
        runInference(prompt: prompt) { result in
            switch result {
            case .none:
                completion(.failed(reason: "model unavailable"))
            case .some(let text):
                let trimmed = Self.unwrapModelOutput(text)
                if trimmed.isEmpty {
                    completion(.failed(reason: "empty response"))
                } else if trimmed == input.text {
                    completion(.unchanged)
                } else {
                    completion(.fixed(trimmed))
                }
            }
        }
    }

    func translateSelection(_ input: AITranslateRequest, completion: @escaping (AITranslateResult) -> Void) {
        guard isReady else {
            completion(.unsupported)
            return
        }
        let prompt = Self.buildTranslatePrompt(input: input)
        runInference(prompt: prompt) { result in
            switch result {
            case .none:
                completion(.failed(reason: "model unavailable"))
            case .some(let text):
                let trimmed = Self.unwrapModelOutput(text)
                if trimmed.isEmpty {
                    completion(.failed(reason: "empty response"))
                } else {
                    completion(.translated(trimmed))
                }
            }
        }
    }

    // MARK: - Inference

    /// Run a single one-shot prompt with timeout. Calls completion with
    /// the response text, or nil on failure / timeout.
    private func runInference(prompt: String, completion: @escaping (String?) -> Void) {
        let session = LanguageModelSession()
        Task.detached(priority: .userInitiated) {
            let task = Task<String?, Never> {
                do {
                    let response = try await session.respond(to: prompt)
                    return response.content
                } catch {
                    return nil
                }
            }
            // Race the inference against a wall-clock timeout.
            let timeout = Task<String?, Never> {
                try? await Task.sleep(nanoseconds: UInt64(Self.inferenceTimeout * 1_000_000_000))
                return nil
            }
            var result: String? = nil
            for await value in [task, timeout].asAsyncSequence() {
                result = value
                task.cancel()
                timeout.cancel()
                break
            }
            completion(result)
        }
    }

    // MARK: - Prompt construction

    private static func buildReviewPrompt(candidate: AICandidate) -> String {
        """
        You are a keyboard-layout fix arbiter. The user typed "\(candidate.originalWord)" and the rules-based engine wants to flip it to "\(candidate.proposedFlip)" (switching the system input source from \(candidate.sourceLayout.displayName) to \(candidate.targetLayout.displayName)).

        Surrounding context (most recent first):
        \(candidate.context.isEmpty ? "(no recent context)" : candidate.context)

        Decide whether the flip is correct given the context. Respond with EXACTLY one word: FLIP, KEEP, or UNKNOWN.
        - FLIP if the proposed rewrite is what the user almost certainly meant.
        - KEEP if the original was probably intentional.
        - UNKNOWN if you cannot tell.
        """
    }

    private static func buildRewritePrompt(input: AIRewriteRequest) -> String {
        let lang = input.preferredLayout.map { $0.displayName } ?? "the input language"
        return """
        Rewrite the following text to fix typos, grammar, and obvious mistakes. Preserve the user's tone and meaning. Output ONLY the corrected text — no explanation, no quotes, no preamble.

        Language hint: \(lang).
        Text:
        \(input.text)
        """
    }

    private static func buildTranslatePrompt(input: AITranslateRequest) -> String {
        """
        Translate the following text into \(input.target.displayName). Auto-detect the source language. Produce an idiomatic, natural translation that a native \(input.target.displayName) speaker would write — not a literal word-for-word rendering. Preserve the original meaning, tone, and any formatting (line breaks, lists). If the source already appears to be in \(input.target.displayName), still produce the most natural \(input.target.displayName) version (lightly polished if needed).

        Output ONLY the translation. No explanation, no quotes, no preamble, no source-language echo.

        Text to translate:
        \(input.text)
        """
    }

    private static func buildFixSelectionPrompt(input: AIFixRequest) -> String {
        let lang = input.activeLayout.map { $0.displayName } ?? "the user's intended language"
        return """
        You are a Mac text-fixing utility. The user selected a chunk of text that may contain a mix of issues:
          • typos and grammar mistakes
          • text accidentally typed in the wrong keyboard layout (e.g. Cyrillic typed on a Latin keyboard or vice-versa, producing apparent gibberish)
          • mid-sentence layout flips that left a word or two in the wrong script
          • inconsistent punctuation or spacing

        Fix everything you can while preserving the user's meaning, tone, and the language they were trying to write in. If the entire text is gibberish from a wrong-layout typing session, reflow it to what the keystrokes would have produced on \(lang). If only a few words are wrong-layout, repair them in place.

        Output ONLY the corrected text. No explanation, no quotes, no preamble, no trailing commentary.

        Selected text:
        \(input.text)
        """
    }

    /// Strip common LM artefacts: leading/trailing whitespace, accidental
    /// surrounding quotes ("…", '…', “…”), markdown code fences. Models
    /// occasionally wrap answers despite "no quotes" instructions.
    private static func unwrapModelOutput(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip code fences ```…```
        if s.hasPrefix("```") {
            if let end = s.range(of: "```", range: s.index(s.startIndex, offsetBy: 3)..<s.endIndex) {
                s = String(s[s.index(s.startIndex, offsetBy: 3)..<end.lowerBound])
                // First line might be a language tag like "text" or "en".
                if let nl = s.firstIndex(of: "\n"), s[..<nl].count <= 12 {
                    s = String(s[s.index(after: nl)...])
                }
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Strip surrounding quotes if both ends match.
        let quotePairs: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}"), ("\u{00AB}", "\u{00BB}")
        ]
        for (l, r) in quotePairs {
            if s.count >= 2, s.first == l, s.last == r {
                s = String(s.dropFirst().dropLast())
                s = s.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return s
    }

    // MARK: - Response parsing

    private static func parseReview(rawText: String?, target: Layout) -> AIDecision {
        guard let raw = rawText?.uppercased() else { return .unknown }
        if raw.contains("FLIP") { return .flip(target: target) }
        if raw.contains("KEEP") { return .dontFlip }
        return .unknown
    }
}

// MARK: - Helpers

private extension Array where Element == Task<String?, Never> {
    /// Convert an array of tasks into a stream of their results in
    /// completion order. First-finished wins.
    func asAsyncSequence() -> AsyncStream<String?> {
        AsyncStream { continuation in
            for task in self {
                Task {
                    let value = await task.value
                    continuation.yield(value)
                }
            }
            // The race in runInference breaks on first yield, so we don't
            // need to formally finish() the stream — caller cancels both.
        }
    }
}

#else

/// Stub for when FoundationModels isn't available at compile time
/// (older Xcode SDKs). Same shape as the real assistant so call sites
/// don't need #if guards.
@available(macOS 26.0, *)
final class FoundationModelsAssistant: AIAssistant {
    var isReady: Bool { false }

    func review(candidateFlip: AICandidate, completion: @escaping (AIDecision) -> Void) {
        completion(.unknown)
    }
}

#endif
