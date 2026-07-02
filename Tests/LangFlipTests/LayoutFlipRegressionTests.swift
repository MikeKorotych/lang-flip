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

    func testMakeAndRunFlipBeforeDictionaryScoredWarmup() {
        XCTAssertEqual(AutoFlip.deterministicFlipTarget(for: "ьфлу", currentLayout: .uk), .en)
        XCTAssertEqual(AutoFlip.deterministicFlipTarget(for: "ьфлу", currentLayout: .ru), .en)
        XCTAssertEqual(AutoFlip.deterministicFlipTarget(for: "кгт", currentLayout: .uk), .en)
        XCTAssertEqual(AutoFlip.deterministicFlipTarget(for: "кгт", currentLayout: .ru), .en)
    }

    func testAutoFlipFallsBackToTypedWordLayoutWhenCurrentLayoutIsUnavailable() {
        let tap = EventTap()
        let candidate = tap.autoFlipCandidate(completedWord: "ьфлу", currentLayout: nil)

        XCTAssertEqual(candidate?.target, .en)
        XCTAssertEqual(convert("ьфлу", from: candidate?.source ?? .uk, to: .en), "make")
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
