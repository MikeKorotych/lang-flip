import Foundation

struct STTAudioUpload {
    let data: Data
    let filename: String
    let cleanupURL: URL?

    func cleanup() {
        guard let cleanupURL else { return }
        try? FileManager.default.removeItem(at: cleanupURL)
    }
}

enum STTAudioUploadPreparer {
    /// Below roughly 31 seconds of 16 kHz mono Int16 WAV, FLAC's encode cost
    /// usually outweighs upload savings on the current backend path.
    private static let compressionThresholdBytes = 1_000_000
    private static let afconvertPath = "/usr/bin/afconvert"

    static func prepareBackendUpload(from audioURL: URL) throws -> STTAudioUpload {
        let originalData = try Data(contentsOf: audioURL)
        guard originalData.count >= compressionThresholdBytes else {
            NetworkLatency.log.info(
                "STT compress=skipped audio=\(originalData.count, privacy: .public)B threshold=\(compressionThresholdBytes, privacy: .public)B"
            )
            return STTAudioUpload(data: originalData, filename: audioURL.lastPathComponent, cleanupURL: nil)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sayful-stt-\(UUID().uuidString).flac")
        let start = DispatchTime.now()
        let ok = convertToFLAC(input: audioURL, output: outputURL)
        let encodeMs = NetworkLatency.elapsedMs(since: start)

        guard ok, let compressedData = try? Data(contentsOf: outputURL) else {
            try? FileManager.default.removeItem(at: outputURL)
            NetworkLatency.log.info(
                "STT compress=failed encode=\(String(format: "%.0f", encodeMs), privacy: .public)ms audio=\(originalData.count, privacy: .public)B"
            )
            return STTAudioUpload(data: originalData, filename: audioURL.lastPathComponent, cleanupURL: nil)
        }

        guard compressedData.count < originalData.count else {
            try? FileManager.default.removeItem(at: outputURL)
            NetworkLatency.log.info(
                "STT compress=larger encode=\(String(format: "%.0f", encodeMs), privacy: .public)ms audio=\(originalData.count, privacy: .public)B flac=\(compressedData.count, privacy: .public)B"
            )
            return STTAudioUpload(data: originalData, filename: audioURL.lastPathComponent, cleanupURL: nil)
        }

        NetworkLatency.log.info(
            "STT compress=flac encode=\(String(format: "%.0f", encodeMs), privacy: .public)ms audio=\(originalData.count, privacy: .public)B flac=\(compressedData.count, privacy: .public)B"
        )
        return STTAudioUpload(data: compressedData, filename: outputURL.lastPathComponent, cleanupURL: outputURL)
    }

    private static func convertToFLAC(input: URL, output: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: afconvertPath)
        process.arguments = [
            input.path,
            output.path,
            "-f", "flac",
            "-d", "flac",
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
