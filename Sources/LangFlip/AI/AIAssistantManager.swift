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
    private var cachedAssistant: AIAssistant = NoopAssistant()
    private let lock = NSLock()

    private init() {}

    /// The assistant matching the current `Settings.aiMode`.
    var current: AIAssistant {
        lock.lock()
        defer { lock.unlock() }
        let mode = Settings.shared.aiMode
        if mode != cachedMode {
            cachedAssistant = Self.makeAssistant(for: mode)
            cachedMode = mode
        }
        return cachedAssistant
    }

    /// Convenience: is the configured assistant ready to take a request?
    /// EventTap consults this before bothering to assemble a prompt.
    var isReady: Bool { current.isReady }

    private static func makeAssistant(for mode: AIMode) -> AIAssistant {
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
        }
    }
}
