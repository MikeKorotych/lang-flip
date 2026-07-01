import XCTest
@testable import LangFlip

final class AppContextTests: XCTestCase {
    func testKnownTerminalBundleIDsAreRecognized() {
        XCTAssertTrue(AppContext.isTerminalBundleID("com.apple.Terminal"))
        XCTAssertTrue(AppContext.isTerminalBundleID("com.googlecode.iterm2"))
        XCTAssertTrue(AppContext.isTerminalBundleID("dev.warp.Warp-Stable"))
        XCTAssertTrue(AppContext.isTerminalBundleID("com.mitchellh.ghostty"))
    }

    func testNonTerminalBundleIDIsNotRecognizedAsTerminal() {
        XCTAssertFalse(AppContext.isTerminalBundleID("com.apple.Notes"))
    }
}
