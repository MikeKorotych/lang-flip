import XCTest
@testable import LangFlip

final class STTTranscriptionPromptTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "lf.dev.sttTranscriptionPromptTemplate")
        super.tearDown()
    }

    func testPromptGuidesLanguageDetectionWithoutKeyboardLayout() {
        let prompt = STTTranscriptionPrompt.defaultText

        XCTAssertTrue(prompt.contains("Українська"))
        XCTAssertTrue(prompt.contains("Русский"))
        XCTAssertTrue(prompt.contains("English"))
        XCTAssertTrue(prompt.contains("Суржик"))
        XCTAssertTrue(prompt.contains("затестить"))
        XCTAssertTrue(prompt.contains("GitHub"))
        XCTAssertTrue(prompt.contains("speech-to-text pipeline"))
    }

    func testPromptCanBeOverriddenFromSettings() {
        UserDefaults.standard.set("CUSTOM STT PROMPT", forKey: "lf.dev.sttTranscriptionPromptTemplate")

        XCTAssertEqual(STTTranscriptionPrompt.current(), "CUSTOM STT PROMPT")
    }
}
