import ApplicationServices
import XCTest
@testable import LangFlip

final class FocusedTextPrivacyTests: XCTestCase {
    func testSecureTextFieldSubroleIsSensitive() {
        XCTAssertTrue(FocusedTextPrivacy.isSensitive(
            role: "AXTextField",
            subrole: kAXSecureTextFieldSubrole as String,
            labels: []
        ))
    }

    func testPasswordAndTokenLabelsAreSensitive() {
        XCTAssertTrue(FocusedTextPrivacy.isSensitive(
            role: "AXTextField",
            subrole: nil,
            labels: ["Password"]
        ))
        XCTAssertTrue(FocusedTextPrivacy.isSensitive(
            role: "AXTextField",
            subrole: nil,
            labels: ["OpenAI API key"]
        ))
        XCTAssertTrue(FocusedTextPrivacy.isSensitive(
            role: "AXTextField",
            subrole: nil,
            labels: ["access_token"]
        ))
    }

    func testNormalTextFieldsAreAllowed() {
        XCTAssertFalse(FocusedTextPrivacy.isSensitive(
            role: "AXTextArea",
            subrole: nil,
            labels: ["Message"]
        ))
        XCTAssertFalse(FocusedTextPrivacy.isSensitive(
            role: "AXTextField",
            subrole: nil,
            labels: ["Search"]
        ))
    }
}
