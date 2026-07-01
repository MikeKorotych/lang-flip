import AppKit

final class SpeechReader: NSObject, NSSpeechSynthesizerDelegate {
    static let shared = SpeechReader()

    private let synthesizer = NSSpeechSynthesizer()
    private var lastSpokenText = ""
    private var lastBackend: TextToSpeechBackend = .cloud
    private(set) var isPaused = false
    private var systemSpeechPaused = false

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
        isPaused = false
        systemSpeechPaused = false
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
        stop(clearPaused: true)
    }

    func pausePlayback() {
        guard isSpeaking else { return }
        if AudioFilePlayer.shared.pause() {
            isPaused = true
            NotificationCenter.default.post(name: .langFlipTTSStateChanged, object: nil)
            return
        }
        if synthesizer.isSpeaking {
            synthesizer.pauseSpeaking(at: .immediateBoundary)
            systemSpeechPaused = true
            isPaused = true
            NotificationCenter.default.post(name: .langFlipTTSStateChanged, object: nil)
        }
    }

    @discardableResult
    func togglePlayback() -> Bool {
        if isSpeaking {
            pausePlayback()
            return true
        }
        return replayLastGeneratedAudio()
    }

    func toggleGeneratedAudio(_ url: URL) {
        if AudioFilePlayer.shared.isCurrent(url) {
            if AudioFilePlayer.shared.isPlaying {
                pausePlayback()
                return
            }
            if AudioFilePlayer.shared.isPaused {
                _ = AudioFilePlayer.shared.resume()
                isPaused = false
                return
            }
        }

        stop(clearPaused: true)
        lastBackend = .cloud
        isPaused = false
        systemSpeechPaused = false
        CloudSpeechSynthesizer.shared.play(url)
    }

    private func stop(clearPaused: Bool) {
        if clearPaused {
            isPaused = false
            systemSpeechPaused = false
        }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking()
        }
        if systemSpeechPaused && clearPaused {
            synthesizer.stopSpeaking()
        }
        OmniVoiceSynthesizer.shared.stop()
        CloudSpeechSynthesizer.shared.stop()
        NotificationCenter.default.post(name: .langFlipTTSStateChanged, object: nil)
    }

    @discardableResult
    func replayLastGeneratedAudio() -> Bool {
        if AudioFilePlayer.shared.resume() {
            isPaused = false
            return true
        }
        if systemSpeechPaused {
            systemSpeechPaused = false
            isPaused = false
            synthesizer.continueSpeaking()
            NotificationCenter.default.post(name: .langFlipTTSStateChanged, object: nil)
            return true
        }
        if lastBackend == .cloud,
           let url = CloudSpeechSynthesizer.shared.lastOutputURL,
           FileManager.default.fileExists(atPath: url.path) {
            isPaused = false
            CloudSpeechSynthesizer.shared.play(url)
            return true
        }
        if lastBackend == .omniVoice,
           let url = OmniVoiceSynthesizer.shared.lastOutputURL,
           FileManager.default.fileExists(atPath: url.path) {
            isPaused = false
            OmniVoiceSynthesizer.shared.play(url)
            return true
        }
        if !lastSpokenText.isEmpty {
            isPaused = false
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
