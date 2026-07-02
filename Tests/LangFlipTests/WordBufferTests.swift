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

    func testNewlineResetsWithoutCompletingWord() {
        let buffer = WordBuffer()

        XCTAssertNil(buffer.feedReturningCompleted("nfr;t\n"))

        XCTAssertEqual(buffer.current, "")
        XCTAssertNil(buffer.lastCompleted)
    }

    func testReplacementWithoutBoundaryBecomesCurrentToken() {
        let buffer = WordBuffer()
        buffer.feed("vj;tn")

        buffer.replaceLastToken(word: "может", boundary: "")

        XCTAssertEqual(buffer.current, "может")
        XCTAssertNil(buffer.lastCompleted)
    }

    func testReplacementWithBoundaryBecomesLastCompletedToken() {
        let buffer = WordBuffer()
        _ = buffer.feedReturningCompleted("vj;tn ")

        buffer.replaceLastToken(word: "может", boundary: " ")

        XCTAssertEqual(buffer.current, "")
        XCTAssertEqual(buffer.lastCompleted?.word, "может")
        XCTAssertEqual(buffer.lastCompleted?.boundary, " ")
    }

    func testSecondSpaceClearsCompletedTokenFallback() {
        let buffer = WordBuffer()

        _ = buffer.feedReturningCompleted("vj;tn ")
        XCTAssertEqual(buffer.lastCompleted?.word, "vj;tn")

        XCTAssertNil(buffer.feedReturningCompleted(" "))

        XCTAssertNil(buffer.lastCompleted)
        XCTAssertEqual(buffer.current, "")
    }
}
