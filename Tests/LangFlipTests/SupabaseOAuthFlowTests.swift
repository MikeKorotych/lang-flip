import XCTest
@testable import LangFlip

final class SupabaseOAuthFlowTests: XCTestCase {
    func testAuthorizeURLCarriesStateInRedirectTo() throws {
        let state = "test-state"
        let url = try SupabaseOAuthFlow.authorizeURL(state: state)

        let authorize = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(authorize.host, BackendConfig.trustedSupabaseHost)
        XCTAssertEqual(authorize.queryItems?.first { $0.name == "provider" }?.value, "google")

        let redirect = try XCTUnwrap(authorize.queryItems?.first { $0.name == "redirect_to" }?.value)
        let callback = try XCTUnwrap(URLComponents(string: redirect))
        XCTAssertEqual(callback.scheme, BackendConfig.callbackScheme)
        XCTAssertEqual(callback.host, "auth-callback")
        XCTAssertEqual(callback.queryItems?.first { $0.name == SupabaseOAuthFlow.callbackStateParameter }?.value, state)
    }

    func testValidateCallbackAcceptsMatchingState() throws {
        let callback = try XCTUnwrap(URL(string: "com.antonpinkevych.sayful://auth-callback?lf_state=expected#access_token=token"))

        XCTAssertNoThrow(try SupabaseOAuthFlow.validateCallback(callback, expectedState: "expected"))
    }

    func testValidateCallbackRejectsMissingOrMismatchedState() throws {
        let missing = try XCTUnwrap(URL(string: "com.antonpinkevych.sayful://auth-callback#access_token=token"))
        let mismatched = try XCTUnwrap(URL(string: "com.antonpinkevych.sayful://auth-callback?lf_state=wrong#access_token=token"))

        XCTAssertThrowsError(try SupabaseOAuthFlow.validateCallback(missing, expectedState: "expected"))
        XCTAssertThrowsError(try SupabaseOAuthFlow.validateCallback(mismatched, expectedState: "expected"))
    }

    func testValidateCallbackRejectsUnexpectedCallbackHost() throws {
        let callback = try XCTUnwrap(URL(string: "com.antonpinkevych.sayful://evil-callback?lf_state=expected#access_token=token"))

        XCTAssertThrowsError(try SupabaseOAuthFlow.validateCallback(callback, expectedState: "expected"))
    }

    func testGeneratedStateIsOpaqueURLSafeAndNonEmpty() throws {
        let first = try SupabaseOAuthFlow.makeState()
        let second = try SupabaseOAuthFlow.makeState()

        XCTAssertFalse(first.isEmpty)
        XCTAssertNotEqual(first, second)
        XCTAssertNil(first.range(of: #"[^A-Za-z0-9_-]"#, options: .regularExpression))
    }
}
