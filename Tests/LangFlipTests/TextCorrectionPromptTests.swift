import XCTest
@testable import LangFlip

final class TextCorrectionPromptTests: XCTestCase {
    func testDefaultPromptInfersOutputLanguageFromInputContext() {
        let prompt = TextCorrectionPrompt.render(
            template: "",
            language: "English",
            allowLayoutRepair: false
        )

        XCTAssertTrue(prompt.contains("Ukrainian, Russian, and English"))
        XCTAssertTrue(prompt.contains("not from the current\nkeyboard layout"))
        XCTAssertTrue(prompt.contains("surzhyk"))
        XCTAssertTrue(prompt.contains("затестить"))
        XCTAssertTrue(prompt.contains("weak layout hint only"))
        XCTAssertFalse(prompt.contains("Treat the current keyboard layout as the intended output language"))
    }

    func testDefaultPromptPreservesMixedLanguageAndSurzhyk() {
        let prompt = TextCorrectionPrompt.preview(language: "user's language", allowLayoutRepair: true)

        XCTAssertTrue(prompt.contains("Preserve mixed\nUkrainian/Russian/English text and surzhyk"))
        XCTAssertTrue(prompt.contains("instead of normalizing or\ntranslating everything into one language"))
        XCTAssertTrue(prompt.contains("individual Ukrainian/Russian code-switching words"))
    }
}
