import Foundation
import os

/// Latency instrumentation for the cloud round-trips that dominate the
/// STT / transform / TTS pipelines.
///
/// Everything logs to the unified logging system under category
/// `latency`. Inspect live with:
///
///     log stream --predicate 'subsystem == "Sayful" AND category == "latency"' --info
///
/// or filter by "latency" in Console.app. Nothing prints to stdout, so this
/// is silent in normal use and free when no one is streaming the subsystem.
///
/// The goal is to split each request into DNS / TCP / TLS / TTFB / download
/// (via `URLSessionTaskMetrics`) plus an end-to-end wall-clock, so we can see
/// where the time actually goes before optimizing — and crucially whether the
/// connection was reused (`reused=true` ⇒ pre-warming won't help that call).
enum NetworkLatency {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sayful", category: "latency")

    /// Milliseconds elapsed since `start` (a `DispatchTime`), formatted.
    static func elapsedMs(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }
}

/// One-shot `URLSessionTaskDelegate` that records the per-transaction timing
/// breakdown and logs a single compact line tagged with `label`.
final class URLSessionMetricsRecorder: NSObject, URLSessionTaskDelegate {
    private let label: String

    init(label: String) {
        self.label = label
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let t = metrics.transactionMetrics.last else { return }

        func ms(_ a: Date?, _ b: Date?) -> String {
            guard let a, let b else { return "—" }
            return String(format: "%.0f", b.timeIntervalSince(a) * 1000)
        }

        let dns = ms(t.domainLookupStartDate, t.domainLookupEndDate)
        let tcp = ms(t.connectStartDate, t.connectEndDate)
        let tls = ms(t.secureConnectionStartDate, t.secureConnectionEndDate)
        let ttfb = ms(t.requestStartDate, t.responseStartDate)
        let download = ms(t.responseStartDate, t.responseEndDate)
        let reused = t.isReusedConnection
        let proto = t.networkProtocolName ?? "?"

        NetworkLatency.log.info(
            "\(self.label, privacy: .public) net dns=\(dns, privacy: .public) tcp=\(tcp, privacy: .public) tls=\(tls, privacy: .public) ttfb=\(ttfb, privacy: .public) dl=\(download, privacy: .public) (ms) reused=\(reused, privacy: .public) proto=\(proto, privacy: .public)"
        )
    }
}

/// Opens a TLS connection to a host ahead of time so the real request reuses
/// it from `URLSession.shared`'s pool — skipping DNS + TCP + TLS (often
/// 100–500 ms) on the latency-critical path.
///
/// We have free network time while the user is still speaking; warming the
/// STT endpoint then means the upload-after-stop reuses a hot connection.
/// Whether it worked shows directly in the next request's metrics line as
/// `reused=true tls=—`.
enum ConnectionWarmer {
    /// Fire-and-forget HEAD to `url`'s host. The HTTP status is irrelevant —
    /// a 4xx still completes the TLS handshake and pools the connection
    /// (keyed on scheme+host+port), which is all we need. Errors are ignored.
    static func warm(_ url: URL, label: String) {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 5
        let start = DispatchTime.now()
        URLSession.shared.dataTask(with: req) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            NetworkLatency.log.info(
                "\(label, privacy: .public) prewarm=\(String(format: "%.0f", NetworkLatency.elapsedMs(since: start)), privacy: .public)ms status=\(status, privacy: .public)"
            )
        }.resume()
    }
}

extension URLSession {
    /// `data(for:)` plus latency instrumentation: logs the network breakdown
    /// (DNS/TCP/TLS/TTFB/download, connection reuse) and an end-to-end
    /// wall-clock for the request, both tagged with `label`.
    func measuredData(for request: URLRequest, label: String) async throws -> (Data, URLResponse) {
        let recorder = URLSessionMetricsRecorder(label: label)
        let start = DispatchTime.now()
        do {
            let result = try await data(for: request, delegate: recorder)
            let ms = NetworkLatency.elapsedMs(since: start)
            let bytes = result.0.count
            NetworkLatency.log.info(
                "\(label, privacy: .public) wall=\(String(format: "%.0f", ms), privacy: .public)ms resp=\(bytes, privacy: .public)B"
            )
            return result
        } catch {
            let ms = NetworkLatency.elapsedMs(since: start)
            NetworkLatency.log.info(
                "\(label, privacy: .public) wall=\(String(format: "%.0f", ms), privacy: .public)ms FAILED \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }
}
