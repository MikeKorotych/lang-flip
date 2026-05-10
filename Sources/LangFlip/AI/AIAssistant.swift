import Foundation

/// Optional second-opinion oracle for the rules-based pipeline.
///
/// LangFlip's core remains rule + dictionary based — fast, deterministic,
/// works offline forever. An `AIAssistant` is a *parallel* check: when the
/// user opts in, the assistant gets the same word + a few words of context
/// and votes on whether the candidate fix matches the user's likely intent.
/// We only auto-flip when both votes agree.
///
/// Implementations:
///   - `FoundationModelsAssistant` — wraps Apple's on-device LM (macOS 26+)
///   - `MLXAssistant` — wraps a downloaded MLX model (Qwen, Gemma, …)
///   - `NoopAssistant` — when the user has AI disabled
///
/// All implementations must return *quickly* (≤ 250 ms warm) and never
/// throw on the hot path — failures fall back to a `nil` decision, which
/// is treated by the caller as "no opinion".
protocol AIAssistant: AnyObject {

    /// Whether this assistant is currently usable. False during model
    /// download, on unsupported OS, etc. Caller checks before submitting.
    var isReady: Bool { get }

    /// Ask the assistant whether the proposed flip is sensible given the
    /// surrounding context. Returns:
    ///   - `.flip(target)` — model agrees we should flip; target language matches our rules result.
    ///   - `.dontFlip` — model thinks the original was fine; the rules side
    ///     should drop its proposal.
    ///   - `.unknown` — model couldn't decide / inference failed; caller
    ///     treats this as a no-op (the rules side decides alone).
    func review(candidateFlip: AICandidate, completion: @escaping (AIDecision) -> Void)

    /// Asynchronously rewrite the given sentence to fix grammar / typos.
    /// Used by the upcoming single-Shift grammar feature; not needed for
    /// the basic flip-review path. Default implementation returns
    /// `.unsupported` so assistants that don't ship sentence rewrite
    /// (e.g. a tiny intent classifier) can opt out.
    func rewriteSentence(_ input: AIRewriteRequest, completion: @escaping (AIRewriteResult) -> Void)

    /// "Fix everything" pass on a chunk of selected text — typos, grammar,
    /// wrong-keyboard-layout gibberish, mixed scripts. Larger contract
    /// than `rewriteSentence`: the model is allowed (encouraged) to make
    /// substantive corrections, not just polish. Used by Sprint F's
    /// smart-selection-flip feature.
    func fixSelection(_ input: AIFixRequest, completion: @escaping (AIFixResult) -> Void)

    /// Translate the given text into `target`. The model is expected to
    /// auto-detect the source language. Used by Sprint G's translate-
    /// selection feature.
    func translateSelection(_ input: AITranslateRequest, completion: @escaping (AITranslateResult) -> Void)

    /// Extract text from an image (OCR). Only meaningful for backends
    /// that support multimodal input — Foundation Models is text-only,
    /// so this returns `.unsupported` there. Ollama with a multimodal
    /// model (Gemma 3+, Qwen 2.5-VL, LLaVA) does the real work.
    func extractTextFromImage(_ input: AIOcrRequest, completion: @escaping (AIOcrResult) -> Void)

    /// Optional cold-start warm-up. Backends with a local runtime can use
    /// this to load the model before the user's first real request.
    func warmUp()
}

extension AIAssistant {
    func rewriteSentence(_ input: AIRewriteRequest, completion: @escaping (AIRewriteResult) -> Void) {
        completion(.unsupported)
    }
    func fixSelection(_ input: AIFixRequest, completion: @escaping (AIFixResult) -> Void) {
        completion(.unsupported)
    }
    func translateSelection(_ input: AITranslateRequest, completion: @escaping (AITranslateResult) -> Void) {
        completion(.unsupported)
    }
    func extractTextFromImage(_ input: AIOcrRequest, completion: @escaping (AIOcrResult) -> Void) {
        completion(.unsupported)
    }
    func warmUp() {}
}

// MARK: - Vote model

struct AICandidate {
    let originalWord: String
    let proposedFlip: String
    /// Surrounding text from the user's word buffer — typically the last
    /// 5–8 words. Empty for selection-mode flips where the candidate is
    /// already the full text.
    let context: String
    let sourceLayout: Layout
    let targetLayout: Layout
}

enum AIDecision: Equatable {
    case flip(target: Layout)
    case dontFlip
    case unknown
}

// MARK: - Sentence rewrite

struct AIRewriteRequest {
    let text: String
    /// Soft hint about the language the user is writing in. Useful for
    /// system prompts; the model is free to ignore.
    let preferredLayout: Layout?
}

enum AIRewriteResult {
    case rewritten(String)   // applied as-is
    case unchanged           // model thought the input was fine
    case unsupported         // assistant doesn't implement this
    case failed(reason: String)
}

// MARK: - Selection fix-everything

struct AIFixRequest {
    /// The full selected text. Length-bounded by the caller — typically
    /// up to a few thousand characters.
    let text: String
    /// Optional hint of the layout the user has currently active. Used
    /// in the system prompt as a soft preference for the output language.
    let activeLayout: Layout?
}

enum AIFixResult {
    case fixed(String)       // applied as-is, replaces selection
    case unchanged           // model thought the input was fine
    case unsupported         // assistant doesn't implement this
    case failed(reason: String)
}

// MARK: - Translation

struct AITranslateRequest {
    /// Source text — language is auto-detected by the model.
    let text: String
    /// Target language. The model is asked to produce idiomatic
    /// translation in this language and nothing else.
    let target: Layout
}

enum AITranslateResult {
    case translated(String)
    case unsupported
    case failed(reason: String)
}

// MARK: - OCR (multimodal)

struct AIOcrRequest {
    /// Base64-encoded image bytes. PNG / JPEG both work for Ollama
    /// multimodal models. Caller is responsible for keeping image
    /// size reasonable — typically a screenshot region under 4 MB.
    let imageBase64: String
}

enum AIOcrResult {
    case extracted(String)   // text exactly as it appears in the image
    case unsupported         // backend / model doesn't do vision
    case failed(reason: String)
}

// MARK: - Default no-op

/// Returned when the user has AI features disabled. Cheap to allocate and
/// safe to call repeatedly.
final class NoopAssistant: AIAssistant {
    var isReady: Bool { false }

    func review(candidateFlip: AICandidate, completion: @escaping (AIDecision) -> Void) {
        completion(.unknown)
    }
}
