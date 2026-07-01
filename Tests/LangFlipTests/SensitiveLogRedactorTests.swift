import XCTest
@testable import LangFlip

final class SensitiveLogRedactorTests: XCTestCase {
    func testRedactsBearerTokensAndKnownSecretFields() {
        let input = """
        Authorization: Bearer sk-test_abcdefghijklmnopqrstuvwxyz
        {"access_token":"eyJhbGciOiJIUzI1NiJ9.payload.signature","refresh_token":"refresh-secret-value"}
        callback?api_key=abc123456789&token=def987654321
        """

        let output = SensitiveLogRedactor.redact(input)

        XCTAssertFalse(output.contains("sk-test_abcdefghijklmnopqrstuvwxyz"))
        XCTAssertFalse(output.contains("eyJhbGciOiJIUzI1NiJ9.payload.signature"))
        XCTAssertFalse(output.contains("refresh-secret-value"))
        XCTAssertFalse(output.contains("abc123456789"))
        XCTAssertFalse(output.contains("def987654321"))
        XCTAssertTrue(output.contains("Authorization: Bearer [REDACTED]"))
        XCTAssertTrue(output.contains(#""access_token":"[REDACTED]""#))
        XCTAssertTrue(output.contains("api_key=[REDACTED]"))
    }

    func testKeepsNonSensitiveDiagnosticsReadable() {
        let input = "STT failed: Transcription provider returned HTTP 429: weekly quota exceeded"

        XCTAssertEqual(SensitiveLogRedactor.redact(input), input)
    }

    func testContentSummaryDoesNotExposeText() {
        let input = "secret launch plan\nsecond line"
        let summary = SensitiveLogRedactor.contentSummary(input)

        XCTAssertTrue(summary.contains("chars="))
        XCTAssertTrue(summary.contains("words=5"))
        XCTAssertTrue(summary.contains("lines=2"))
        XCTAssertFalse(summary.contains("secret"))
        XCTAssertFalse(summary.contains("launch"))
    }
}
