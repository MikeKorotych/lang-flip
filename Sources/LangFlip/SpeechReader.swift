import AppKit

final class SpeechReader: NSObject, NSSpeechSynthesizerDelegate {
    static let shared = SpeechReader()

    private let synthesizer = NSSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
        applySettings()
    }

    var isSpeaking: Bool {
        synthesizer.isSpeaking || OmniVoiceSynthesizer.shared.isSpeaking
    }

    static var availableVoices: [String] {
        NSSpeechSynthesizer.availableVoices.map(\.rawValue)
    }

    static func displayName(for voice: String) -> String {
        let name = NSSpeechSynthesizer.VoiceName(rawValue: voice)
        let attrs = NSSpeechSynthesizer.attributes(forVoice: name)
        return attrs[NSSpeechSynthesizer.VoiceAttributeKey.name] as? String ?? voice
    }

    func speak(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        stop()
        if Settings.shared.ttsBackend == .omniVoice {
            _ = OmniVoiceSynthesizer.shared.speak(clean)
            return
        }
        applySettings()
        synthesizer.startSpeaking(clean)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking()
        }
        OmniVoiceSynthesizer.shared.stop()
    }

    func applySettings() {
        let voice = Settings.shared.speechVoiceIdentifier
        if !voice.isEmpty {
            synthesizer.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: voice))
        }
        synthesizer.rate = Float(Settings.shared.speechRate)
    }
}
