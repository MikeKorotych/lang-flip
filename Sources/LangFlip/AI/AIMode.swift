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

    var id: Self { self }

    var displayName: String {
        switch self {
        case .off:              return "Off"
        case .appleFoundation:  return "Apple Intelligence (macOS 26+)"
        case .bundledModel:     return "Downloaded model"
        }
    }
}
