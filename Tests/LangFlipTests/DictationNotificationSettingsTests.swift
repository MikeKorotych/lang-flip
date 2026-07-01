import XCTest
@testable import LangFlip

final class DictationNotificationSettingsTests: XCTestCase {
    private let key = "lf.dictationNotifications"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func testDictationNotificationsDefaultOnForActionableFailures() {
        XCTAssertTrue(Settings.shared.dictationNotifications)
    }

    func testDictationNotificationsCanBeDisabled() {
        Settings.shared.dictationNotifications = false

        XCTAssertFalse(Settings.shared.dictationNotifications)
    }
}
