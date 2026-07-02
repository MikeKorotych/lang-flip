import XCTest
@testable import LangFlip

final class STTTranscriptionPromptTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "lf.dev.sttTranscriptionPromptTemplate")
        super.tearDown()
    }

    func testDefaultPromptIsEmptyForBaselineTesting() {
        XCTAssertEqual(STTTranscriptionPrompt.defaultText, "")
        XCTAssertNil(STTTranscriptionPrompt.current())
    }

    func testWhitespacePromptIsNotSent() {
        UserDefaults.standard.set(" \n\t ", forKey: "lf.dev.sttTranscriptionPromptTemplate")

        XCTAssertNil(STTTranscriptionPrompt.current())
    }

    func testLegacyVocabularyPromptIsCleared() {
        UserDefaults.standard.set(STTTranscriptionPrompt.legacyVocabularyPrompt, forKey: "lf.dev.sttTranscriptionPromptTemplate")

        XCTAssertNil(STTTranscriptionPrompt.current())
        XCTAssertNil(UserDefaults.standard.string(forKey: "lf.dev.sttTranscriptionPromptTemplate"))
    }

    func testPromptCanBeOverriddenFromSettings() {
        UserDefaults.standard.set("CUSTOM STT PROMPT", forKey: "lf.dev.sttTranscriptionPromptTemplate")

        XCTAssertEqual(STTTranscriptionPrompt.current(), "CUSTOM STT PROMPT")
    }
}
