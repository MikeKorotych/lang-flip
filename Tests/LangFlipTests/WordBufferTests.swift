import XCTest
@testable import LangFlip

final class WordBufferTests: XCTestCase {
    func testSemicolonStaysInsideWrongLayoutWordUntilWhitespace() {
        let buffer = WordBuffer()

        XCTAssertNil(buffer.feedReturningCompleted("vj;tv"))
        let completed = buffer.feedReturningCompleted(" ")

        XCTAssertEqual(completed?.word, "vj;tv")
        XCTAssertEqual(completed?.boundary, " ")
    }

    func testTrailingPunctuationIsPreservedAsBoundary() {
        let buffer = WordBuffer()

        XCTAssertNil(buffer.feedReturningCompleted("ghbdtn!"))
        let completed = buffer.feedReturningCompleted(" ")

        XCTAssertEqual(completed?.word, "ghbdtn")
        XCTAssertEqual(completed?.boundary, "! ")
    }
}
