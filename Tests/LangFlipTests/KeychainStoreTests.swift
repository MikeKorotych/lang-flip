import Security
import XCTest
@testable import LangFlip

final class KeychainStoreTests: XCTestCase {
    func testStoredSecretsAreThisDeviceOnlyAndNotSynchronizable() {
        let data = Data("secret".utf8)

        let addQuery = KeychainStore.addQuery(account: "unit-test", data: data)
        let updateAttrs = KeychainStore.storageAttributes(data: data)

        XCTAssertEqual(addQuery[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(updateAttrs[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(addQuery[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(updateAttrs[kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testBaseQueryIsScopedToAppServiceAndSingleAccount() {
        let query = KeychainStore.baseQuery(account: KeychainStore.backendAccessToken)

        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, KeychainStore.service)
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, KeychainStore.backendAccessToken)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
    }
}
