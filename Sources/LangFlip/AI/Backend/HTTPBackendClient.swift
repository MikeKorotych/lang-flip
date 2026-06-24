import Foundation

/// `BackendClient` over HTTPS against the Supabase Edge Functions (`/functions/v1`).
/// Attaches the session bearer + anon apikey, refreshes once on 401, and maps
/// the server's error envelope to `BackendError`.
final class HTTPBackendClient: BackendClient {
    static let shared = HTTPBackendClient()

    private let auth: SupabaseBackendAuth
    private let base = BackendConfig.functionsBaseURL

    init(auth: SupabaseBackendAuth = .shared) { self.auth = auth }

    // MARK: BackendClient

    func chat(_ request: BackendChatRequest) async throws -> BackendTextResult {
        let data = try await send("chat", jsonBody: request)
        return try BackendJSON.decoder.decode(BackendTextResult.self, from: data)
    }

    func ocr(_ request: BackendOCRRequest) async throws -> BackendTextResult {
        let data = try await send("ocr", jsonBody: request)
        return try BackendJSON.decoder.decode(BackendTextResult.self, from: data)
    }

    func transcribe(_ request: BackendTranscribeRequest) async throws -> BackendTextResult {
        let boundary = "lf-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(request.filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(request.audio)
        body.append("\r\n".data(using: .utf8)!)
        if let model = request.model { field("model", model) }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let data = try await send("transcribe", rawBody: body,
                                  contentType: "multipart/form-data; boundary=\(boundary)")
        return try BackendJSON.decoder.decode(BackendTextResult.self, from: data)
    }

    func tts(_ request: BackendTTSRequest) async throws -> Data {
        try await send("tts", jsonBody: request)
    }

    // MARK: - Transport

    private func send<Body: Encodable>(_ path: String, jsonBody: Body) async throws -> Data {
        let data = try JSONEncoder().encode(jsonBody)
        return try await send(path, rawBody: data, contentType: "application/json")
    }

    private func send(_ path: String, rawBody: Data, contentType: String, isRetry: Bool = false) async throws -> Data {
        let token = try await auth.currentBearerToken()
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(BackendConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = rawBody

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw BackendError(code: .network, message: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw BackendError(code: .network, message: "No response")
        }

        if http.statusCode == 401 && !isRetry {
            try await auth.refreshSession()
            return try await send(path, rawBody: rawBody, contentType: contentType, isRetry: true)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw decodeError(data, status: http.statusCode)
        }
        return data
    }

    private func decodeError(_ data: Data, status: Int) -> BackendError {
        guard let env = try? BackendJSON.decoder.decode(BackendError.Envelope.self, from: data) else {
            return BackendError(code: status == 429 ? .rateLimited : .server, message: "Request failed (\(status))")
        }
        let code = BackendError.Code(rawValue: env.error.code) ?? (status == 429 ? .quotaExceeded : .server)
        return BackendError(code: code, message: env.error.message, resetAt: env.error.details?.resetAt)
    }
}
