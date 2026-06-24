import AppKit
import AuthenticationServices
import Foundation

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

    var isSignedIn: Bool {
        KeychainStore.getString(account: KeychainStore.backendAccessToken)?.isEmpty == false
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
        var comps = URLComponents(url: BackendConfig.authBaseURL.appendingPathComponent("authorize"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "provider", value: "google"),
            .init(name: "redirect_to", value: BackendConfig.callbackURL),
        ]
        guard let authURL = comps.url else {
            throw BackendError(code: .unknown, message: "Could not build the sign-in URL")
        }

        let callback = try await presentWebAuth(url: authURL)
        let tokens = try parseTokens(from: callback)
        store(tokens)
        return try await refreshUser()
    }

    func refreshUser() async throws -> BackendUser {
        let token = try await currentBearerToken()
        var req = URLRequest(url: BackendConfig.functionsBaseURL.appendingPathComponent("me"))
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
