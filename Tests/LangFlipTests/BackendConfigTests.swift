import XCTest
@testable import LangFlip

final class BackendConfigTests: XCTestCase {
    private let overrideKey = "lf.backendSupabaseURL"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: overrideKey)
        super.tearDown()
    }

    func testSupabaseURLIgnoresMutableUserDefaultsOverride() {
        UserDefaults.standard.set("https://attacker.example", forKey: overrideKey)

        XCTAssertEqual(BackendConfig.supabaseURL, BackendConfig.defaultSupabaseURL)
        XCTAssertEqual(BackendConfig.authBaseURL.host, BackendConfig.trustedSupabaseHost)
        XCTAssertEqual(BackendConfig.functionsBaseURL.host, BackendConfig.trustedSupabaseHost)
    }

    func testTrustedBackendURLRejectsUnexpectedHostBeforeCredentialsAreAttached() {
        let attacker = URL(string: "https://attacker.example/functions/v1/chat")!

        XCTAssertFalse(BackendConfig.isTrustedBackendURL(attacker))
        XCTAssertThrowsError(try BackendConfig.requireTrustedBackendURL(attacker))
    }

    func testTrustedBackendURLAcceptsConfiguredSupabaseHTTPSHost() {
        let url = BackendConfig.functionsBaseURL.appendingPathComponent("chat")

        XCTAssertTrue(BackendConfig.isTrustedBackendURL(url))
        XCTAssertNoThrow(try BackendConfig.requireTrustedBackendURL(url))
    }
}
