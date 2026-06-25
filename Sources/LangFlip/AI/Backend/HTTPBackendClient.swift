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

    func reserveSTT(_ request: BackendSTTReserveRequest) async throws -> BackendSTTReserveResult {
        let data = try await send("stt-reserve", jsonBody: request)
        return try BackendJSON.decoder.decode(BackendSTTReserveResult.self, from: data)
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

        var headers: [String: String] = [:]
        if let reservationID = request.reservationID, !reservationID.isEmpty {
            headers["X-Stt-Reservation"] = reservationID
        }
        let data = try await send("transcribe", rawBody: body,
                                  contentType: "multipart/form-data; boundary=\(boundary)",
                                  extraHeaders: headers)
        return try BackendJSON.decoder.decode(BackendTextResult.self, from: data)
    }

    func tts(_ request: BackendTTSRequest) async throws -> Data {
        try await send("tts", jsonBody: request)
    }

    func ttsPCMStream(
        _ request: BackendTTSRequest,
        onResponse: (BackendPCMStreamInfo) throws -> Void,
        onChunk: (Data) throws -> Void
    ) async throws -> BackendPCMStreamInfo {
        var streamingRequest = request
        streamingRequest.stream = "pcm"
        let body = try JSONEncoder().encode(streamingRequest)
        return try await stream("tts", rawBody: body, contentType: "application/json", onResponse: onResponse, onChunk: onChunk)
    }

    // MARK: - Transport

    private func send<Body: Encodable>(_ path: String, jsonBody: Body) async throws -> Data {
        let data = try JSONEncoder().encode(jsonBody)
        return try await send(path, rawBody: data, contentType: "application/json")
    }

    private func makeRequest(path: String, token: String, rawBody: Data, contentType: String, extraHeaders: [String: String] = [:]) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(BackendConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for (name, value) in extraHeaders {
            req.setValue(value, forHTTPHeaderField: name)
        }
        req.httpBody = rawBody
        return req
    }

    private func send(_ path: String, rawBody: Data, contentType: String, extraHeaders: [String: String] = [:], isRetry: Bool = false) async throws -> Data {
        let token = try await auth.currentBearerToken()
        let req = makeRequest(path: path, token: token, rawBody: rawBody, contentType: contentType, extraHeaders: extraHeaders)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.measuredData(for: req, label: latencyLabel(for: path))
        } catch {
            throw BackendError(code: .network, message: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw BackendError(code: .network, message: "No response")
        }

        if http.statusCode == 401 && !isRetry {
            try await auth.refreshSession()
            return try await send(path, rawBody: rawBody, contentType: contentType, extraHeaders: extraHeaders, isRetry: true)
        }
        guard (200..<300).contains(http.statusCode) else {
            let err = decodeError(data, status: http.statusCode)
            // Weekly quota hit — surface a clear system notification once, from
            // this single choke point so every feature (dictate / read-aloud /
            // fix / translate / screen-text) reports it consistently.
            if err.code == .quotaExceeded || err.code == .rateLimited {
                Notifications.show(
                    title: "Weekly limit reached",
                    body: "You've used up your weekly Sayful Cloud limit. It resets automatically — try again after the reset.")
            }
            throw err
        }
        // Live quota: the server returns the updated counters on every call.
        if let used = Int(http.value(forHTTPHeaderField: "X-Quota-Used") ?? ""),
           let limit = Int(http.value(forHTTPHeaderField: "X-Quota-Limit") ?? "") {
            let reset = http.value(forHTTPHeaderField: "X-Quota-Reset")
            await auth.applyQuotaHeaders(used: used, limit: limit, resetISO: reset)
        }
        return data
    }

    private func stream(
        _ path: String,
        rawBody: Data,
        contentType: String,
        isRetry: Bool = false,
        onResponse: (BackendPCMStreamInfo) throws -> Void,
        onChunk: (Data) throws -> Void
    ) async throws -> BackendPCMStreamInfo {
        let token = try await auth.currentBearerToken()
        let req = makeRequest(path: path, token: token, rawBody: rawBody, contentType: contentType)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: req)
        } catch {
            throw BackendError(code: .network, message: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw BackendError(code: .network, message: "No response")
        }

        if http.statusCode == 401 && !isRetry {
            try await auth.refreshSession()
            return try await stream(path, rawBody: rawBody, contentType: contentType, isRetry: true, onResponse: onResponse, onChunk: onChunk)
        }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 64 * 1024 { break }
            }
            throw decodeError(data, status: http.statusCode)
        }

        if let used = Int(http.value(forHTTPHeaderField: "X-Quota-Used") ?? ""),
           let limit = Int(http.value(forHTTPHeaderField: "X-Quota-Limit") ?? "") {
            let reset = http.value(forHTTPHeaderField: "X-Quota-Reset")
            await auth.applyQuotaHeaders(used: used, limit: limit, resetISO: reset)
        }

        var info = BackendPCMStreamInfo(
            sampleRate: Int(http.value(forHTTPHeaderField: "X-Audio-Sample-Rate") ?? "") ?? 24_000,
            channels: Int(http.value(forHTTPHeaderField: "X-Audio-Channels") ?? "") ?? 1,
            contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "audio/L16"
        )
        try onResponse(info)

        var chunk = Data()
        chunk.reserveCapacity(8192)
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= 8192 {
                info.bytes += chunk.count
                try onChunk(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty {
            info.bytes += chunk.count
            try onChunk(chunk)
        }
        return info
    }

    private func latencyLabel(for path: String) -> String {
        switch path {
        case "transcribe": return "STT"
        case "stt-reserve": return "STT reserve"
        case "chat": return "AI"
        case "ocr": return "OCR"
        case "tts": return "TTS"
        default: return "Backend \(path)"
        }
    }

    private func decodeError(_ data: Data, status: Int) -> BackendError {
        guard let env = try? BackendJSON.decoder.decode(BackendError.Envelope.self, from: data) else {
            return BackendError(code: status == 429 ? .rateLimited : .server, message: "Request failed (\(status))")
        }
        let code = BackendError.Code(rawValue: env.error.code) ?? (status == 429 ? .quotaExceeded : .server)
        return BackendError(code: code, message: env.error.message, resetAt: env.error.details?.resetAt)
    }
}
