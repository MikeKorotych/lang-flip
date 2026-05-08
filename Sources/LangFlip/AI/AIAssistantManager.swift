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

    private var cachedMode: AIMode?
    /// For Ollama we also key the cache on the model name so swapping
    /// "gemma3" → "qwen2.5" rebuilds the assistant.
    private var cachedOllamaModel: String?
    private var cachedAssistant: AIAssistant = NoopAssistant()
    private let lock = NSLock()

    private init() {}

    /// The assistant matching the current `Settings.aiMode`.
    var current: AIAssistant {
        lock.lock()
        defer { lock.unlock() }
        let mode = Settings.shared.aiMode
        let ollamaModel = Settings.shared.ollamaModel
        let modeChanged   = mode != cachedMode
        let modelChanged  = (mode == .ollama) && (ollamaModel != cachedOllamaModel)
        if modeChanged || modelChanged {
            cachedAssistant = Self.makeAssistant(for: mode, ollamaModel: ollamaModel)
            cachedMode = mode
            cachedOllamaModel = ollamaModel
        }
        return cachedAssistant
    }

    /// Convenience: is the configured assistant ready to take a request?
    /// EventTap consults this before bothering to assemble a prompt.
    var isReady: Bool { current.isReady }

    private static func makeAssistant(for mode: AIMode, ollamaModel: String) -> AIAssistant {
        switch mode {
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
            return OllamaAssistant(model: ollamaModel)
        }
    }
}
