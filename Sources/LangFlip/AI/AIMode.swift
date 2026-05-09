import Foundation

/// User-facing AI assistant choice. Persisted in `Settings.shared.aiMode`.
///
/// The default is `.off` — LangFlip ships AI as a strict opt-in, both
/// because the AI features are still being validated and because users
/// who installed for the rules-based behaviour shouldn't be surprised by
/// background model loads on first launch.
enum AIMode: String, CaseIterable, Identifiable {
    /// AI features disabled. The rules pipeline runs alone.
    case off

    /// Apple's on-device Foundation Models (macOS 26+ only). Free, no
    /// download, system-managed. Falls back to `.off` on older OSes.
    case appleFoundation

    /// A locally-downloaded model run via MLX. The active model identifier
    /// is stored separately in Settings.shared.activeModelID so users can
    /// switch between e.g. Qwen 2.5 1.5B, Gemma 3 1B, Phi-3.5 Mini.
    case bundledModel

    /// A model served by a locally-running Ollama daemon
    /// (https://ollama.com). Zero in-app integration cost — the user
    /// installs Ollama separately and `ollama pull <model>`s whatever
    /// they want; LangFlip just hits localhost:11434/api/generate. The
    /// model name lives in Settings.shared.ollamaModel.
    case ollama

    /// A cloud LLM accessed via an OpenAI-compatible chat-completions
    /// API. BYOK — user pastes their own key. Default endpoint is
    /// OpenAI itself, but the same backend works for OpenRouter,
    /// Together, Fireworks, Groq, Anthropic-via-proxy, etc. — the
    /// user changes the base URL.
    case openai

    var id: Self { self }

    var displayName: String {
        switch self {
        case .off:              return "Off"
        case .appleFoundation:  return "Apple Intelligence (macOS 26+)"
        case .bundledModel:     return "Downloaded model (MLX)"
        case .ollama:           return "Ollama (local)"
        case .openai:           return "OpenAI / compatible cloud (BYOK)"
        }
    }
}
