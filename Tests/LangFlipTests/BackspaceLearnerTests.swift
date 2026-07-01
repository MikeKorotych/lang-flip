import XCTest
@testable import LangFlip

final class BackspaceLearnerTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private var previousAutomaticLearning: Any?
    private var previousExceptions: [String]?

    override func setUp() {
        super.setUp()
        previousAutomaticLearning = defaults.object(forKey: LocalContentPrivacy.automaticLearningKey)
        previousExceptions = defaults.array(forKey: BackspaceLearner.exceptionsKey) as? [String]
        defaults.set(true, forKey: LocalContentPrivacy.automaticLearningKey)
        BackspaceLearner.shared.clearExceptions()
    }

    override func tearDown() {
        BackspaceLearner.shared.clearExceptions()
        if let previousExceptions {
            for word in previousExceptions {
                BackspaceLearner.shared.addException(word)
            }
        }
        if let previousAutomaticLearning {
            defaults.set(previousAutomaticLearning, forKey: LocalContentPrivacy.automaticLearningKey)
        } else {
            defaults.removeObject(forKey: LocalContentPrivacy.automaticLearningKey)
        }
        super.tearDown()
    }

    func testAddExceptionReportsOnlyNewInsertions() {
        XCTAssertTrue(BackspaceLearner.shared.addException("ьфлу"))
        XCTAssertFalse(BackspaceLearner.shared.addException("ЬФЛУ"))
        XCTAssertTrue(BackspaceLearner.shared.isExcluded("ьфлу"))
    }

    func testExceptionNotificationNamesAddedWord() {
        XCTAssertEqual(
            BackspaceLearner.exceptionNotificationBody(for: "ьфлу"),
            "Added \"ьфлу\" to exceptions. Sayful will leave it as typed."
        )
    }
}
