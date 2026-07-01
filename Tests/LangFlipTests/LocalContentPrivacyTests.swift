import XCTest
@testable import LangFlip

final class LocalContentPrivacyTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "LocalContentPrivacyTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalContentPrivacyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let suiteName {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        defaults = nil
        suiteName = nil
        tempRoot = nil
        try super.tearDownWithError()
    }

    func testRetentionAndAutomaticLearningDefaultToCurrentLocalUX() {
        XCTAssertTrue(LocalContentPrivacy.retainsLocalContentHistory(defaults: defaults))
        XCTAssertTrue(LocalContentPrivacy.allowsAutomaticLearning(defaults: defaults))
    }

    func testPurgeLocalContentHistoryRemovesStoredHistoryAndMediaFiles() throws {
        defaults.set(Data("dictation".utf8), forKey: DictationHistory.storageKey)
        defaults.set(Data("ocr".utf8), forKey: OCRHistory.storageKey)
        defaults.set(Data("tts".utf8), forKey: TTSHistory.storageKey)

        let recordings = tempRoot.appendingPathComponent("Recordings", isDirectory: true)
        let tts = tempRoot.appendingPathComponent("TTS", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tts, withIntermediateDirectories: true)
        let recording = recordings.appendingPathComponent("dictation.wav")
        let generatedSpeech = tts.appendingPathComponent("speech.wav")
        try Data("audio".utf8).write(to: recording)
        try Data("tts".utf8).write(to: generatedSpeech)

        LocalContentPrivacy.purgeLocalContentHistory(
            defaults: defaults,
            recordingsDirectory: recordings,
            ttsDirectory: tts
        )

        XCTAssertNil(defaults.object(forKey: DictationHistory.storageKey))
        XCTAssertNil(defaults.object(forKey: OCRHistory.storageKey))
        XCTAssertNil(defaults.object(forKey: TTSHistory.storageKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: generatedSpeech.path))
    }

    func testPurgeAutomaticLearningKeepsManualDictionaryEntriesOnly() throws {
        let manual = PersonalDictionaryEntry(
            canonical: "UniTech",
            variants: ["unitech"],
            source: .manual
        )
        let automatic = PersonalDictionaryEntry(
            canonical: "Sayful",
            variants: ["safe full"],
            source: .automatic
        )
        defaults.set(try JSONEncoder().encode([manual, automatic]), forKey: PersonalDictionaryStore.storageKey)
        defaults.set(["secret-project"], forKey: BackspaceLearner.exceptionsKey)

        LocalContentPrivacy.purgeAutomaticLearning(defaults: defaults)

        let data = try XCTUnwrap(defaults.data(forKey: PersonalDictionaryStore.storageKey))
        let decoded = try JSONDecoder().decode([PersonalDictionaryEntry].self, from: data)
        XCTAssertEqual(decoded, [manual])
        XCTAssertNil(defaults.object(forKey: BackspaceLearner.exceptionsKey))
    }
}
