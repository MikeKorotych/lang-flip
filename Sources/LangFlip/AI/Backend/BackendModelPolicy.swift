import Foundation

enum BackendModelPolicy {
    static func textCorrectionModelOverride() -> String? {
        nil
    }

    static func ocrModelOverride() -> String? {
        nil
    }

    static func ttsModelOverride() -> String? {
        nil
    }

    static func sttModelOverride(for mode: DictationTranscriptionMode) -> String? {
        mode.backendModelOverride
    }

    static func displayName(_ model: String?) -> String {
        model ?? "server-default"
    }
}
