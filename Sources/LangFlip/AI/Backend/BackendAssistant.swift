import Foundation

/// `AIAssistant` that routes text + OCR through the corporate backend proxy
/// (`.backend` mode). No provider key in the app — the backend holds it and
/// enforces per-user quotas. Mirrors `OpenAIAssistant`'s prompts; chat-shaped
/// features call `/v1/chat`, OCR calls `/v1/ocr`.
final class BackendAssistant: AIAssistant {
    private let client: BackendClient

    init(client: BackendClient = HTTPBackendClient.shared) { self.client = client }

    var isReady: Bool { SupabaseBackendAuth.shared.isSignedIn }

    // The flip-arbiter is a keystroke hot-path; not worth a network round-trip.
    func review(candidateFlip: AICandidate, completion: @escaping (AIDecision) -> Void) {
        completion(.unknown)
    }

    func rewriteSentence(_ input: AIRewriteRequest, completion: @escaping (AIRewriteResult) -> Void) {
        let lang = input.preferredLayout?.displayName ?? "input language"
        chat(system: Self.rewritePrompt(language: lang, allowLayoutRepair: false), input: input.text) { res in
            switch res {
            case .success(let text):
                completion(text == input.text ? .unchanged : .rewritten(text))
            case .failure(let reason):
                completion(.failed(reason: reason))
            }
        }
    }

    func fixSelection(_ input: AIFixRequest, completion: @escaping (AIFixResult) -> Void) {
        let lang = input.activeLayout?.displayName ?? "user's language"
        chat(system: Self.rewritePrompt(language: lang, allowLayoutRepair: true), input: input.text) { res in
            switch res {
            case .success(let text):
                if text.isEmpty { completion(.failed(reason: "empty response")) }
                else if text == input.text { completion(.unchanged) }
                else { completion(.fixed(text)) }
            case .failure(let reason):
                completion(.failed(reason: reason))
            }
        }
    }

    func translateSelection(_ input: AITranslateRequest, completion: @escaping (AITranslateResult) -> Void) {
        let target = input.target.displayName
        let system = "Translate the user's text into \(target). Do not answer, explain, or continue the text. Preserve meaning and formatting. Output ONLY the translation, no quotes."
        chat(system: system, input: input.text) { res in
            switch res {
            case .success(let text):
                completion(text.isEmpty ? .failed(reason: "empty response") : .translated(text))
            case .failure(let reason):
                completion(.failed(reason: reason))
            }
        }
    }

    func applyTransform(_ input: AITransformRequest, completion: @escaping (AITransformResult) -> Void) {
        let system = """
        You transform the user's text according to this instruction:

        \(input.instruction)

        Output ONLY the transformed text — no preamble, no explanation, no quotes, no markdown fences.
        """
        chat(system: system, input: input.text) { res in
            switch res {
            case .success(let text):
                completion(text.isEmpty ? .failed(reason: "empty response") : .transformed(text))
            case .failure(let reason):
                completion(.failed(reason: reason))
            }
        }
    }

    func formatDictation(_ input: AIDictationFormatRequest, completion: @escaping (AIDictationFormatResult) -> Void) {
        chat(system: Self.dictationFormatPrompt, input: input.text) { res in
            switch res {
            case .success(let text):
                if text.isEmpty { completion(.failed(reason: "empty response")) }
                else if text == input.text { completion(.unchanged) }
                else { completion(.formatted(text)) }
            case .failure(let reason):
                completion(.failed(reason: reason))
            }
        }
    }

    func extractTextFromImage(_ input: AIOcrRequest, completion: @escaping (AIOcrResult) -> Void) {
        Task {
            do {
                let result = try await client.ocr(BackendOCRRequest(imageBase64: input.imageBase64, model: nil))
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                completion(text.isEmpty ? .failed(reason: "model returned no text") : .extracted(text))
            } catch {
                completion(.failed(reason: Self.message(error)))
            }
        }
    }

    // MARK: - Helpers

    private enum ChatResult { case success(String); case failure(String) }

    private func chat(system: String, input: String, completion: @escaping (ChatResult) -> Void) {
        Task {
            do {
                let result = try await client.chat(BackendChatRequest(system: system, input: input))
                completion(.success(result.text.trimmingCharacters(in: .whitespacesAndNewlines)))
            } catch {
                completion(.failure(Self.message(error)))
            }
        }
    }

    private static func message(_ error: Error) -> String {
        guard let be = error as? BackendError else { return error.localizedDescription }
        switch be.code {
        case .quotaExceeded:   return "Weekly word limit reached"
        case .unauthenticated: return "Sign in to use AI"
        case .rateLimited:     return "Too many requests — slow down"
        default:               return be.message
        }
    }

    /// Structure-only cleanup of a dictation transcript. The hard rule is to
    /// preserve the speaker's exact words — only fix formatting.
    private static let dictationFormatPrompt = """
    You format raw speech-to-text dictation inside a macOS dictation app.
    Improve ONLY the formatting and structure of the transcript:
    - Fix capitalization, punctuation, and spacing.
    - Merge fragments that were split only because the speaker paused into
      coherent sentences and paragraphs.
    - When the text lists or enumerates items, format them as a clean bulleted
      or numbered list.
    - Keep natural paragraph breaks.
    Hard rules: do NOT rephrase, reword, translate, summarize, add, or remove
    content. Preserve the speaker's exact words, vocabulary, names, numbers, and
    meaning. Keep the same language as the input.
    Output ONLY the formatted text — no preamble, no explanation, no quotes, no
    code fences.
    """

    private static func rewritePrompt(language: String, allowLayoutRepair: Bool) -> String {
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
}
