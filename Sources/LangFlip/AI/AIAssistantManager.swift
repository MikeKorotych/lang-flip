import Foundation

/// Singleton that hands the right AIAssistant to the rest of the app
/// based on `Settings.shared.aiMode`.
///
///   - `.off`              → cached `NoopAssistant`
///   - `.appleFoundation`  → `FoundationModelsAssistant` on macOS 26+,
///                          `NoopAssistant` otherwise
///   - `.bundledModel`     → `MLXAssistant` (Sprint D); for now,
///                          `NoopAssistant`
///
/// The manager re-evaluates the mode lazily on each `current` access and
/// caches the resolved assistant until the mode changes — keeps inference
/// state warm across calls without imposing a hot-reload cost.
final class AIAssistantManager {
    static let shared = AIAssistantManager()

    /// We key the cache on every input that would change the
    /// resolved assistant so Settings edits in Preferences propagate
    /// without an app restart.
    private struct CacheKey: Equatable {
        let mode: AIMode
        let ollamaModel: String?
        let openaiModel: String?
        let openaiBaseURL: String?
        let openaiHasKey: Bool
    }
    private var cachedKey: CacheKey?
    private var cachedAssistant: AIAssistant = NoopAssistant()
    private let lock = NSLock()

    private init() {}

    /// The assistant matching the current `Settings.aiMode`.
    var current: AIAssistant {
        lock.lock()
        defer { lock.unlock() }
        let key = currentKey()
        if key != cachedKey {
            cachedAssistant = Self.makeAssistant(for: key)
            cachedKey = key
        }
        return cachedAssistant
    }

    /// Convenience: is the configured assistant ready to take a request?
    /// EventTap consults this before bothering to assemble a prompt.
    var isReady: Bool { current.isReady }

    private func currentKey() -> CacheKey {
        let mode = Settings.shared.aiMode
        return CacheKey(
            mode:           mode,
            ollamaModel:    mode == .ollama  ? Settings.shared.ollamaModel : nil,
            openaiModel:    mode == .openai  ? Settings.shared.openaiModel : nil,
            openaiBaseURL:  mode == .openai  ? Settings.shared.openaiBaseURL : nil,
            openaiHasKey:   mode == .openai  ? !(Settings.shared.openaiAPIKey?.isEmpty ?? true) : false
        )
    }

    private static func makeAssistant(for key: CacheKey) -> AIAssistant {
        switch key.mode {
        case .off:
            return NoopAssistant()
        case .appleFoundation:
            if #available(macOS 26.0, *) {
                return FoundationModelsAssistant()
            } else {
                return NoopAssistant()
            }
        case .bundledModel:
            // Sprint D will wire MLXAssistant here.
            return NoopAssistant()
        case .ollama:
            return OllamaAssistant(model: key.ollamaModel ?? "qwen3.5:4b")
        case .openai:
            // No API key → no point building an assistant that will
            // 401 on every call. NoopAssistant short-circuits the
            // whole pipeline so the EventTap stays silent.
            guard let apiKey = Settings.shared.openaiAPIKey, !apiKey.isEmpty else {
                return NoopAssistant()
            }
            return OpenAIAssistant(
                apiKey: apiKey,
                model: key.openaiModel ?? "gpt-5-nano",
                baseURLString: key.openaiBaseURL ?? "https://api.openai.com/v1"
            )
        }
    }
}
