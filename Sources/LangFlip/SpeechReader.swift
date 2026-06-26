import AppKit

final class SpeechReader: NSObject, NSSpeechSynthesizerDelegate {
    static let shared = SpeechReader()

    private let synthesizer = NSSpeechSynthesizer()
    private var lastSpokenText = ""
    private var lastBackend: TextToSpeechBackend = .cloud

    private override init() {
        super.init()
        synthesizer.delegate = self
        applySettings()
    }

    var isSpeaking: Bool {
        synthesizer.isSpeaking || OmniVoiceSynthesizer.shared.isSpeaking || CloudSpeechSynthesizer.shared.isSpeaking
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
        lastSpokenText = clean
        lastBackend = Settings.shared.ttsBackend
        if lastBackend == .omniVoice {
            _ = OmniVoiceSynthesizer.shared.speak(clean)
            return
        }
        if lastBackend == .cloud {
            _ = CloudSpeechSynthesizer.shared.speak(clean)
            return
        }
        applySettings()
        synthesizer.startSpeaking(clean)
        NotificationCenter.default.post(name: .langFlipTTSStateChanged, object: nil)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking()
        }
        OmniVoiceSynthesizer.shared.stop()
        CloudSpeechSynthesizer.shared.stop()
        NotificationCenter.default.post(name: .langFlipTTSStateChanged, object: nil)
    }

    @discardableResult
    func replayLastGeneratedAudio() -> Bool {
        if lastBackend == .cloud, let url = CloudSpeechSynthesizer.shared.lastOutputURL {
            CloudSpeechSynthesizer.shared.play(url)
            return true
        }
        if lastBackend == .omniVoice, let url = OmniVoiceSynthesizer.shared.lastOutputURL {
            OmniVoiceSynthesizer.shared.play(url)
            return true
        }
        if !lastSpokenText.isEmpty {
            speak(lastSpokenText)
            return true
        }
        return false
    }

    func applySettings() {
        let voice = Settings.shared.speechVoiceIdentifier
        if !voice.isEmpty {
            synthesizer.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: voice))
        }
        synthesizer.rate = Float(Settings.shared.speechRate)
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        NotificationCenter.default.post(name: .langFlipTTSStateChanged, object: nil)
    }
}
