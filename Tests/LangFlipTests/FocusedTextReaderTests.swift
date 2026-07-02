import XCTest
@testable import LangFlip

final class FocusedTextReaderTests: XCTestCase {
    func testTextFieldIsPasteTargetEvenWhenValueCannotBeRead() {
        XCTAssertTrue(FocusedTextReader.isLikelyTextInput(
            role: "AXTextField",
            subrole: nil,
            hasSelectedTextRange: false,
            hasSettableValue: false
        ))
    }

    func testWebEditorWithSelectionRangeIsPasteTarget() {
        XCTAssertTrue(FocusedTextReader.isLikelyTextInput(
            role: "AXWebArea",
            subrole: nil,
            hasSelectedTextRange: true,
            hasSettableValue: false
        ))
    }

    func testNonTextControlIsNotPasteTarget() {
        XCTAssertFalse(FocusedTextReader.isLikelyTextInput(
            role: "AXButton",
            subrole: nil,
            hasSelectedTextRange: false,
            hasSettableValue: true
        ))
    }
}
