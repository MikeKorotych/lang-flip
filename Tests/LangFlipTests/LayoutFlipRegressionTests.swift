import XCTest
@testable import LangFlip

final class LayoutFlipRegressionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AutoFlip.shared.ensureReadyForTyping()
    }

    func testAutoFlipCanCorrectFirstMakeTypedOnCyrillicLayoutAfterWarmup() {
        XCTAssertEqual(convert("ьфлу", from: .uk, to: .en), "make")
        XCTAssertEqual(AutoFlip.shared.suggestedFlip(for: "ьфлу", currentLayout: .uk), .en)
    }

    func testBilIsNotAcceptedAsUkrainianDictionarySignal() {
        XCTAssertFalse(AutoFlip.shared.isKnown("біл", in: .uk))
        XCTAssertFalse(AutoFlip.shared.isKnownInUk("біл"))
        XCTAssertTrue(AutoFlip.shared.isKnown("был", in: .ru))
    }

    func testDoubleShiftEnglishGibberishChoosesRussianWhenUkrainianPrimaryIsFalsePositive() {
        let tap = EventTap()

        XCTAssertEqual(convert(",sk", from: .en, to: .uk), "біл")
        XCTAssertEqual(convert(",sk", from: .en, to: .ru), "был")
        XCTAssertEqual(tap.resolveManualTarget(source: .en, token: ",sk", configured: .uk), .ru)
    }

    func testAutoFlipEnglishSkChoosesRussianBylInsteadOfUkrainianBil() {
        XCTAssertEqual(AutoFlip.shared.suggestedFlip(for: ",sk", currentLayout: .en), .ru)
    }
}
