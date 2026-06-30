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
        chat(
            system: TextCorrectionPrompt.system(language: lang, allowLayoutRepair: false),
            input: input.text,
            temperature: 0,
            maxTokens: Self.fastTextEditMaxTokens(inputCharacterCount: input.text.count, cap: 256),
            model: Self.devTextCorrectionModelOverride()
        ) { res in
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
        chat(
            system: TextCorrectionPrompt.system(language: lang, allowLayoutRepair: true),
            input: input.text,
            temperature: 0,
            maxTokens: Self.fastTextEditMaxTokens(inputCharacterCount: input.text.count, cap: 512),
            model: Self.devTextCorrectionModelOverride()
        ) { res in
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
        chat(system: system, input: input.text, temperature: 0.2, maxTokens: 1024) { res in
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
        chat(system: system, input: input.text, temperature: 0.3, maxTokens: 2048) { res in
            switch res {
            case .success(let text):
                completion(text.isEmpty ? .failed(reason: "empty response") : .transformed(text))
            case .failure(let reason):
                completion(.failed(reason: reason))
            }
        }
    }

    func formatDictation(_ input: AIDictationFormatRequest, completion: @escaping (AIDictationFormatResult) -> Void) {
        chat(
            system: Self.dictationFormatPrompt,
            input: input.text,
            temperature: 0,
            maxTokens: Self.fastTextEditMaxTokens(inputCharacterCount: input.text.count, cap: 2048, padding: 256)
        ) { res in
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
                let model = Settings.shared.cloudOCRModel.trimmingCharacters(in: .whitespacesAndNewlines)
                let result = try await client.ocr(BackendOCRRequest(
                    imageBase64: input.imageBase64,
                    model: model.isEmpty ? nil : model
                ))
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                completion(text.isEmpty ? .failed(reason: "model returned no text") : .extracted(text))
            } catch {
                completion(.failed(reason: Self.message(error)))
            }
        }
    }

    // MARK: - Helpers

    private enum ChatResult { case success(String); case failure(String) }

    private func chat(system: String, input: String, temperature: Double? = nil, maxTokens: Int? = nil, model: String? = nil, completion: @escaping (ChatResult) -> Void) {
        Task {
            do {
                let result = try await client.chat(BackendChatRequest(system: system, input: input, temperature: temperature, maxTokens: maxTokens, model: model))
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

    private static func fastTextEditMaxTokens(inputCharacterCount: Int, cap: Int, padding: Int = 64) -> Int {
        max(64, min(cap, (inputCharacterCount / 2) + padding))
    }

    private static func devTextCorrectionModelOverride() -> String? {
        let model = Settings.shared.devTextCorrectionModel
        return model.isEmpty ? nil : model
    }

    /// Structure-only cleanup of a dictation transcript. The hard rule is to
    /// preserve the speaker's exact words — only fix formatting.
    private static let dictationFormatPrompt = """
    You format raw speech-to-text dictation inside a macOS dictation app.
    Treat this as the same minimal-edit text cleanup used for selected text,
    but stricter: speech transcripts should be formatted, not rewritten.

    Primary goal: fix punctuation, capitalization, spacing, paragraph breaks,
    list formatting, and quote formatting with the smallest possible edit.
    Merge fragments that were split only because the speaker paused into
    coherent sentences and paragraphs.

    For medium and long dictations, actively split the output into logical
    paragraphs. Prefer 2-5 compact paragraphs over one large wall of text. If
    the transcript is roughly 60+ words and contains more than one thought,
    avoid returning a single paragraph unless the speaker clearly dictated one
    continuous thought. Start a new paragraph when the speaker changes topic,
    moves from problem to reasoning, gives examples, introduces a new
    requirement, contrasts options, asks a question, or makes a concluding/
    next-step statement. Use a blank line between paragraphs. Do not split after
    every sentence; keep tightly related sentences together.

    Preserve the speaker's exact words, vocabulary, tone, language, slang,
    loanwords, authenticity, names, numbers, code, URLs, markdown, and meaning.
    Do not rewrite for style. Do not improve the text beyond formatting it. Do
    not add new concepts. Do not summarize. Do not translate.

    Change a word only when it is an obvious speech-to-text recognition artifact
    and the intended replacement is strongly implied by the nearby words. If a
    slang or borrowed word is understandable and preserves the speaker's voice,
    keep it. Do not normalize or respell borrowed/transliterated words such as
    "полишинг", "полішинг", "апдейт", "фича", or "фіча" only to make them
    sound more native.

    Capitalization fixes are expected: start complete sentences and list items
    with a capital letter unless the item intentionally starts with code, a URL,
    a username, or a brand style.

    Visual structure is formatting, not rewriting. When the transcript clearly
    enumerates multiple items, format that part as a clean numbered or bulleted
    list. If the speaker lists desired changes, requirements, test cases,
    purchases, steps, pros/cons, examples, UI issues, or next actions, make the
    list visually scannable instead of keeping it inside one paragraph. Do not
    leave three or more comma-separated features, options, examples, or
    requirements inline inside a long sentence after phrases like "I want to
    add", "хочу добавить", "я бы хотел", "нужно", "можно попробовать",
    "например", "по пунктам", or "следующие"; split them into bullets or short
    separate lines while preserving the original wording.

    When a verb of speech introduces direct words (for example "сказать",
    "сказав", "said", "told"), use a colon and quotation marks for the spoken
    phrase if the boundary is clear.

    Do not over-punctuate. Avoid adding a comma after ordinary opening time
    words such as "сегодня", "сьогодні", or "today" unless grammar requires it.
    Never write "Сегодня, я" or "Сьогодні, я"; write "Сегодня я" or
    "Сьогодні я".

    Output ONLY the formatted text — no preamble, no explanation, no quotes, no
    code fences.
    """

}
