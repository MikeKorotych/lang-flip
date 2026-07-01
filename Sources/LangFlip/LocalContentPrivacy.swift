import Foundation

/// Central policy for user-content retention on this Mac.
///
/// Product default preserves the current local-only UX: history and learning
/// stay available on this Mac. Privacy-sensitive deployments can explicitly
/// opt out, which also purges the corresponding local artifacts.
enum LocalContentPrivacy {
    static let retainLocalContentHistoryKey = "lf.privacy.retainLocalContentHistory"
    static let automaticLearningKey = "lf.privacy.automaticLearning"

    static let defaultRetainsLocalContentHistory = true
    static let defaultAllowsAutomaticLearning = true

    static var retainsLocalContentHistory: Bool {
        get { retainsLocalContentHistory(defaults: .standard) }
        set { setRetainsLocalContentHistory(newValue) }
    }

    static var allowsAutomaticLearning: Bool {
        get { allowsAutomaticLearning(defaults: .standard) }
        set { setAllowsAutomaticLearning(newValue) }
    }

    static func retainsLocalContentHistory(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: retainLocalContentHistoryKey) as? Bool ?? defaultRetainsLocalContentHistory
    }

    static func allowsAutomaticLearning(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: automaticLearningKey) as? Bool ?? defaultAllowsAutomaticLearning
    }

    static func setRetainsLocalContentHistory(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: retainLocalContentHistoryKey)
        guard !enabled, defaults === UserDefaults.standard else { return }

        DictationHistory.shared.deleteAll()
        OCRHistory.shared.deleteAll()
        TTSHistory.shared.deleteAll()
        purgeLocalContentHistory(defaults: defaults)
    }

    static func setAllowsAutomaticLearning(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: automaticLearningKey)
        guard !enabled, defaults === UserDefaults.standard else { return }

        PersonalDictionaryStore.shared.clearAutomatic()
        BackspaceLearner.shared.clearExceptions()
        purgeAutomaticLearning(defaults: defaults)
    }

    static func enforceOnLaunch() {
        if !retainsLocalContentHistory {
            purgeLocalContentHistory()
        }
        if !allowsAutomaticLearning {
            purgeAutomaticLearning()
        }
    }

    static func purgeLocalContentHistory(
        defaults: UserDefaults = .standard,
        recordingsDirectory: URL = VoiceRecorder.recordingsDirectory,
        ttsDirectory: URL = CloudSpeechSynthesizer.outputDirectory
    ) {
        [
            DictationHistory.storageKey,
            OCRHistory.storageKey,
            TTSHistory.storageKey,
        ].forEach { defaults.removeObject(forKey: $0) }

        purgeDirectory(recordingsDirectory)
        purgeDirectory(ttsDirectory)
    }

    static func purgeAutomaticLearning(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: BackspaceLearner.exceptionsKey)

        guard let data = defaults.data(forKey: PersonalDictionaryStore.storageKey),
              let decoded = try? JSONDecoder().decode([PersonalDictionaryEntry].self, from: data)
        else { return }

        let manualOnly = decoded.filter { $0.source != .automatic }
        if manualOnly.isEmpty {
            defaults.removeObject(forKey: PersonalDictionaryStore.storageKey)
        } else if manualOnly.count != decoded.count,
                  let encoded = try? JSONEncoder().encode(manualOnly) {
            defaults.set(encoded, forKey: PersonalDictionaryStore.storageKey)
        }
    }

    private static func purgeDirectory(_ directory: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        for url in files {
            try? fm.removeItem(at: url)
        }
    }
}
