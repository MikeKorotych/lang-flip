import AppKit
import AuthenticationServices
import Foundation
import Security

/// `BackendAuth` for the Supabase branch. Drives Google sign-in via Supabase
/// GoTrue + `ASWebAuthenticationSession` (no SDK dependency), stores the
/// session tokens in Keychain, refreshes them, and loads the user via `/me`.
///
/// The app holds only a Supabase session JWT — never the provider key.
@MainActor
final class SupabaseBackendAuth: NSObject, ObservableObject, BackendAuth {
    static let shared = SupabaseBackendAuth()

    @Published private(set) var currentUser: BackendUser?

    private var webSession: ASWebAuthenticationSession?

    private override init() {
        super.init()
    }

    // MARK: BackendAuth

    nonisolated static var hasStoredSession: Bool {
        KeychainStore.getString(account: KeychainStore.backendAccessToken)?.isEmpty == false
    }

    nonisolated var isSignedIn: Bool {
        Self.hasStoredSession
    }

    func currentBearerToken() async throws -> String {
        if let token = KeychainStore.getString(account: KeychainStore.backendAccessToken), !token.isEmpty {
            return token
        }
        throw BackendError(code: .unauthenticated, message: "Not signed in")
    }

    /// Google sign-in through Supabase. Opens the system auth sheet, captures
    /// the token fragment from the callback, persists it, then loads `/me`.
    func signIn() async throws -> BackendUser {
        let state = try SupabaseOAuthFlow.makeState()
        let authURL = try SupabaseOAuthFlow.authorizeURL(state: state)
        let callback = try await presentWebAuth(url: authURL)
        try SupabaseOAuthFlow.validateCallback(callback, expectedState: state)
        let tokens = try parseTokens(from: callback)
        store(tokens)
        return try await refreshUser()
    }

    func refreshUser() async throws -> BackendUser {
        let token = try await currentBearerToken()
        let url = BackendConfig.functionsBaseURL.appendingPathComponent("me")
        try BackendConfig.requireTrustedBackendURL(url)

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(BackendConfig.anonKey, forHTTPHeaderField: "apikey")

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        if http?.statusCode == 401 {
            // Try one refresh, then retry once.
            try await refreshSession()
            return try await refreshUser()
        }
        guard let http, (200..<300).contains(http.statusCode) else {
            throw BackendError(code: .server, message: "Could not load account")
        }
        struct MeResponse: Decodable { let user: BackendUser }
        let me = try BackendJSON.decoder.decode(MeResponse.self, from: data)
        currentUser = me.user
        return me.user
    }

    func signOut() {
        _ = KeychainStore.delete(account: KeychainStore.backendAccessToken)
        _ = KeychainStore.delete(account: KeychainStore.backendRefreshToken)
        currentUser = nil
    }

    /// Update the cached quota from a proxy response's `X-Quota-*` headers, so
    /// the account UI reflects usage live without a `/me` round-trip.
    func applyQuotaHeaders(used: Int, limit: Int, resetISO: String?) {
        guard let u = currentUser else { return }
        let reset = resetISO.flatMap(Self.parseISO) ?? u.quota.resetAt
        currentUser = BackendUser(id: u.id, email: u.email, role: u.role,
                                  quota: BackendQuota(used: used, limit: limit, resetAt: reset))
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
    static func parseISO(_ s: String) -> Date? { isoFrac.date(from: s) ?? isoPlain.date(from: s) }

    // MARK: Refresh

    /// Exchange the refresh token for a fresh access token (GoTrue).
    func refreshSession() async throws {
        guard let refresh = KeychainStore.getString(account: KeychainStore.backendRefreshToken), !refresh.isEmpty else {
            throw BackendError(code: .unauthenticated, message: "Session expired — sign in again")
        }
        var req = URLRequest(url: BackendConfig.authBaseURL.appendingPathComponent("token"))
        req.url = URLComponents(url: req.url!, resolvingAgainstBaseURL: false).map {
            var c = $0; c.queryItems = [.init(name: "grant_type", value: "refresh_token")]; return c
        }?.url
        try BackendConfig.requireTrustedBackendURL(req.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(BackendConfig.anonKey, forHTTPHeaderField: "apikey")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refresh])

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let tokens = try? parseTokens(fromJSON: data) else {
            signOut()
            throw BackendError(code: .unauthenticated, message: "Session expired — sign in again")
        }
        store(tokens)
    }

    // MARK: - Helpers

    private struct Tokens { let access: String; let refresh: String }

    private func store(_ t: Tokens) {
        _ = KeychainStore.setString(t.access, account: KeychainStore.backendAccessToken)
        if !t.refresh.isEmpty {
            _ = KeychainStore.setString(t.refresh, account: KeychainStore.backendRefreshToken)
        }
    }

    /// Supabase returns tokens in the URL *fragment* on the OAuth callback.
    private func parseTokens(from callback: URL) throws -> Tokens {
        let fragment = callback.fragment ?? ""
        var dict: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { dict[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1]) }
        }
        guard let access = dict["access_token"], !access.isEmpty else {
            if let err = dict["error_description"] { throw BackendError(code: .unauthenticated, message: err) }
            throw BackendError(code: .unauthenticated, message: "Sign-in did not return a session")
        }
        return Tokens(access: access, refresh: dict["refresh_token"] ?? "")
    }

    private func parseTokens(fromJSON data: Data) throws -> Tokens {
        struct Refreshed: Decodable { let access_token: String; let refresh_token: String }
        let r = try JSONDecoder().decode(Refreshed.self, from: data)
        return Tokens(access: r.access_token, refresh: r.refresh_token)
    }

    private func presentWebAuth(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: BackendConfig.callbackScheme
            ) { callbackURL, error in
                if let callbackURL {
                    cont.resume(returning: callbackURL)
                } else if let error {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    cont.resume(throwing: BackendError(
                        code: cancelled ? .unauthenticated : .network,
                        message: cancelled ? "Sign-in cancelled" : error.localizedDescription))
                } else {
                    cont.resume(throwing: BackendError(code: .unknown, message: "Sign-in failed"))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.webSession = session
            if !session.start() {
                cont.resume(throwing: BackendError(code: .unknown, message: "Could not start sign-in"))
            }
        }
    }
}

extension SupabaseBackendAuth: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.keyWindow ?? NSWindow()
    }
}

enum SupabaseOAuthFlow {
    static let callbackStateParameter = "lf_state"

    static func makeState(byteCount: Int = 32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw BackendError(code: .unknown, message: "Could not prepare sign-in")
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func authorizeURL(state: String) throws -> URL {
        var comps = URLComponents(
            url: BackendConfig.authBaseURL.appendingPathComponent("authorize"),
            resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "provider", value: "google"),
            .init(name: "redirect_to", value: try callbackURL(state: state)),
        ]
        guard let url = comps.url else {
            throw BackendError(code: .unknown, message: "Could not build the sign-in URL")
        }
        try BackendConfig.requireTrustedBackendURL(url)
        return url
    }

    static func callbackURL(state: String) throws -> String {
        guard !state.isEmpty,
              var comps = URLComponents(string: BackendConfig.callbackURL) else {
            throw BackendError(code: .unknown, message: "Could not build the sign-in callback")
        }
        comps.queryItems = [.init(name: callbackStateParameter, value: state)]
        guard let url = comps.url else {
            throw BackendError(code: .unknown, message: "Could not build the sign-in callback")
        }
        return url.absoluteString
    }

    static func validateCallback(_ callback: URL, expectedState: String) throws {
        guard let expected = URLComponents(string: BackendConfig.callbackURL),
              let actual = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              actual.scheme == expected.scheme,
              actual.host == expected.host,
              actual.path == expected.path else {
            throw BackendError(code: .unauthenticated, message: "Invalid sign-in callback")
        }

        let state = actual.queryItems?.first { $0.name == callbackStateParameter }?.value
        guard !expectedState.isEmpty, state == expectedState else {
            throw BackendError(code: .unauthenticated, message: "Invalid sign-in state")
        }
    }
}
