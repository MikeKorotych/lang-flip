import Foundation

// WS1 — backend proxy client contract (macOS side).
//
// Mirrors the shared API contract in docs/WS1-BACKEND-PROXY-SPEC.md §5. The app
// never holds a provider key in `.backend` mode — only a session bearer token.
// Two auth backends (Supabase / custom Railway) sit behind `BackendAuth`; the
// `/v1/*` proxy calls are identical and live behind `BackendClient`.
//
// This file is the interface layer only (types + protocols). Concrete HTTP /
// auth implementations land in follow-up steps once a backend endpoint exists.

// MARK: - Config (non-secret)

enum BackendConfig {
    /// Base URL of the backend proxy (e.g. https://…/functions/v1 or the Railway
    /// service). Differs per branch/env; NOT a secret. Empty until provisioned.
    static var baseURL: URL? {
        let raw = UserDefaults.standard.string(forKey: "lf.backendBaseURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : URL(string: raw)
    }

    /// Whether a backend base URL is configured (so the UI can gate `.backend`).
    static var isConfigured: Bool { baseURL != nil }
}

// MARK: - User / quota DTOs (spec §5.1)

enum BackendRole: String, Codable {
    case corporate
    case free
}

struct BackendQuota: Codable, Equatable {
    let used: Int
    let limit: Int
    let resetAt: Date

    var remaining: Int { max(0, limit - used) }
}

struct BackendUser: Codable, Equatable {
    let id: String
    let email: String
    let role: BackendRole
    let quota: BackendQuota
}

// MARK: - Proxy request/response DTOs (spec §5.2)

/// Result of a text-producing endpoint (chat / transcribe / ocr). `words` is the
/// metered word count the server charged.
struct BackendTextResult: Codable, Equatable {
    let text: String
    let words: Int
}

struct BackendChatRequest: Codable {
    let system: String
    let input: String
    var temperature: Double?
    var maxTokens: Int?
    var model: String?
}

struct BackendTTSRequest: Codable {
    let text: String
    var voice: String?
    var model: String?
    var speed: Double?
    var instructions: String?
}

struct BackendOCRRequest: Codable {
    let imageBase64: String
    var model: String?
}

/// A transcription upload (sent as multipart/form-data, not JSON).
struct BackendTranscribeRequest {
    let audio: Data
    let filename: String
    var language: String?
    var model: String?
}

// MARK: - Errors (spec §5 error envelope + §5.4 codes)

struct BackendError: Error, Equatable {
    enum Code: String {
        case unauthenticated
        case quotaExceeded = "quota_exceeded"
        case rateLimited = "rate_limited"
        case badRequest = "bad_request"
        case server = "server_error"
        case network
        case notConfigured        // no base URL / not signed in (client-side)
        case unknown
    }

    let code: Code
    let message: String
    /// For `quotaExceeded`: when the weekly window resets.
    var resetAt: Date?

    /// Decodes the server's `{ "error": { code, message, details } }` envelope.
    struct Envelope: Decodable {
        struct Inner: Decodable {
            let code: String
            let message: String
            struct Details: Decodable { let resetAt: Date? }
            let details: Details?
        }
        let error: Inner
    }
}

// MARK: - Auth (spec §5.1, §7) — Supabase vs custom Railway behind one protocol

protocol BackendAuth: AnyObject {
    var isSignedIn: Bool { get }

    /// The signed-in user (with current quota), if known.
    var currentUser: BackendUser? { get }

    /// A valid bearer token for `/v1/*`, refreshing if needed. Throws
    /// `.unauthenticated` if the user must sign in again.
    func currentBearerToken() async throws -> String

    /// Run the Google sign-in flow and exchange for a backend session.
    func signIn() async throws -> BackendUser

    /// Refresh the cached user/quota from `GET /me`.
    func refreshUser() async throws -> BackendUser

    func signOut()
}

// MARK: - Proxy client (spec §5.2)

protocol BackendClient: AnyObject {
    func chat(_ request: BackendChatRequest) async throws -> BackendTextResult
    func transcribe(_ request: BackendTranscribeRequest) async throws -> BackendTextResult
    func tts(_ request: BackendTTSRequest) async throws -> Data
    func ocr(_ request: BackendOCRRequest) async throws -> BackendTextResult
}
