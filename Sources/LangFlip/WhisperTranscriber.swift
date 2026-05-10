import Foundation

enum WhisperTranscriber {
    struct DownloadProgress {
        let fraction: Double
        let bytesWritten: Int64
        let bytesExpected: Int64
        let currentFile: String
    }

    enum Model: String, CaseIterable, Identifiable {
        case tiny
        case base
        case small
        case largeV3Turbo

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .tiny: return "Whisper tiny"
            case .base: return "Whisper base"
            case .small: return "Whisper small"
            case .largeV3Turbo: return "Whisper large-v3-turbo"
            }
        }

        var filename: String {
            switch self {
            case .tiny: return "ggml-tiny.bin"
            case .base: return "ggml-base.bin"
            case .small: return "ggml-small.bin"
            case .largeV3Turbo: return "ggml-large-v3-turbo.bin"
            }
        }

        var approximateSize: String {
            switch self {
            case .tiny: return "78 MB"
            case .base: return "148 MB"
            case .small: return "488 MB"
            case .largeV3Turbo: return "1.55 GB"
            }
        }

        var note: String {
            switch self {
            case .tiny: return "Fast smoke test"
            case .base: return "Light baseline"
            case .small: return "Better daily quality"
            case .largeV3Turbo: return "Best Whisper target"
            }
        }

        var downloadURL: URL {
            URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")!
        }

        var localURL: URL {
            modelsDirectory.appendingPathComponent(filename)
        }
    }

    enum QwenASR {
        static let displayName = "Qwen3-ASR-1.7B"
        static let approximateSize = "4.7 GB"
        static let repoURL = URL(string: "https://huggingface.co/Qwen/Qwen3-ASR-1.7B")!
        static let directory = modelsDirectory.appendingPathComponent("Qwen3-ASR-1.7B", isDirectory: true)

        static let files: [(name: String, size: Int64)] = [
            ("chat_template.json", 1_161),
            ("config.json", 6_194),
            ("generation_config.json", 142),
            ("preprocessor_config.json", 330),
            ("tokenizer_config.json", 12_487),
            ("vocab.json", 2_776_833),
            ("merges.txt", 1_671_853),
            ("model.safetensors.index.json", 64_821),
            ("model-00001-of-00002.safetensors", 4_220_320_824),
            ("model-00002-of-00002.safetensors", 478_200_688),
        ]

        static var isInstalled: Bool {
            files.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.name).path) }
        }

        static func fileURL(_ filename: String) -> URL {
            URL(string: "https://huggingface.co/Qwen/Qwen3-ASR-1.7B/resolve/main/\(filename)")!
        }
    }

    struct Availability {
        let executableURL: URL?
        let modelURL: URL?

        var isReady: Bool {
            executableURL != nil && modelURL != nil
        }
    }

    static func availability() -> Availability {
        Availability(
            executableURL: executableURL(),
            modelURL: modelURL()
        )
    }

    static func transcribe(audioURL: URL, language: String) async throws -> String {
        guard let executableURL = executableURL() else {
            throw TranscriptionError.missingExecutable
        }
        guard let modelURL = modelURL() else {
            throw TranscriptionError.missingModel
        }

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = executableURL
            process.arguments = [
                "-m", modelURL.path,
                "-f", audioURL.path,
                "-l", language.isEmpty ? "auto" : language,
                "-nt",
                "-np"
            ]
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let output = String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard process.terminationStatus == 0 else {
                throw TranscriptionError.processFailed(errorOutput.isEmpty ? output : errorOutput)
            }
            guard !output.isEmpty else {
                throw TranscriptionError.emptyResult(errorOutput)
            }
            return output
        }.value
    }

    static func defaultModelCandidates() -> [URL] {
        [
            Model.largeV3Turbo.localURL,
            Model.small.localURL,
            Model.base.localURL,
            Model.tiny.localURL,
            URL(fileURLWithPath: "/opt/homebrew/share/whisper-cpp/for-tests-ggml-tiny.bin"),
            URL(fileURLWithPath: "/opt/homebrew/Cellar/whisper-cpp/1.8.4/share/whisper-cpp/for-tests-ggml-tiny.bin"),
        ]
    }

    static var modelsDirectory: URL {
        URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/LangFlip/Models", isDirectory: true)
    }

    static func isInstalled(_ model: Model) -> Bool {
        FileManager.default.fileExists(atPath: model.localURL.path)
    }

    static func download(_ model: Model, progress: @escaping @MainActor (DownloadProgress) -> Void = { _ in }) async throws -> URL {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        return try await FileDownloader.download(
            from: model.downloadURL,
            to: model.localURL,
            displayName: model.filename,
            progress: progress
        )
    }

    static func downloadQwenASR(progress: @escaping @MainActor (DownloadProgress) -> Void = { _ in }) async throws -> URL {
        try FileManager.default.createDirectory(at: QwenASR.directory, withIntermediateDirectories: true)
        let totalBytes = QwenASR.files.reduce(Int64(0)) { $0 + $1.size }
        var completedBytes: Int64 = 0

        for file in QwenASR.files {
            let destination = QwenASR.directory.appendingPathComponent(file.name)
            if FileManager.default.fileExists(atPath: destination.path) {
                completedBytes += file.size
                continue
            }

            _ = try await FileDownloader.download(
                from: QwenASR.fileURL(file.name),
                to: destination,
                displayName: file.name
            ) { fileProgress in
                let currentWritten = fileProgress.bytesWritten
                let aggregateWritten = completedBytes + currentWritten
                let aggregateFraction = totalBytes > 0 ? Double(aggregateWritten) / Double(totalBytes) : fileProgress.fraction
                Task { @MainActor in
                    progress(DownloadProgress(
                        fraction: min(1, max(0, aggregateFraction)),
                        bytesWritten: aggregateWritten,
                        bytesExpected: totalBytes,
                        currentFile: file.name
                    ))
                }
            }
            completedBytes += file.size
        }

        await progress(DownloadProgress(
            fraction: 1,
            bytesWritten: totalBytes,
            bytesExpected: totalBytes,
            currentFile: "done"
        ))
        return QwenASR.directory
    }

    static func executableCandidates() -> [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli"),
            URL(fileURLWithPath: "/usr/local/bin/whisper-cli"),
            URL(fileURLWithPath: "/opt/homebrew/bin/whisper"),
            URL(fileURLWithPath: "/usr/local/bin/whisper"),
        ]
    }

    private static func executableURL() -> URL? {
        executableCandidates().first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func modelURL() -> URL? {
        let configured = Settings.shared.whisperModelPath
        if !configured.isEmpty {
            let url = URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return defaultModelCandidates().first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

private final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    private let destinationURL: URL
    private let displayName: String
    private let progress: @MainActor (WhisperTranscriber.DownloadProgress) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var downloadedURL: URL?
    private var session: URLSession?
    private var didResume = false

    private init(
        destinationURL: URL,
        displayName: String,
        progress: @escaping @MainActor (WhisperTranscriber.DownloadProgress) -> Void
    ) {
        self.destinationURL = destinationURL
        self.displayName = displayName
        self.progress = progress
        super.init()
    }

    static func download(
        from sourceURL: URL,
        to destinationURL: URL,
        displayName: String,
        progress: @escaping @MainActor (WhisperTranscriber.DownloadProgress) -> Void
    ) async throws -> URL {
        let downloader = FileDownloader(
            destinationURL: destinationURL,
            displayName: displayName,
            progress: progress
        )
        return try await downloader.start(sourceURL)
    }

    private func start(_ sourceURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = session
            session.downloadTask(with: sourceURL).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        Task { @MainActor in
            progress(WhisperTranscriber.DownloadProgress(
                fraction: min(1, max(0, fraction)),
                bytesWritten: totalBytesWritten,
                bytesExpected: totalBytesExpectedToWrite,
                currentFile: displayName
            ))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let directory = destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            downloadedURL = destinationURL
        } catch {
            resume(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            resume(.failure(error))
        } else if let downloadedURL {
            resume(.success(downloadedURL))
        } else {
            resume(.failure(TranscriptionError.processFailed("Download finished without a file.")))
        }
        session.invalidateAndCancel()
    }

    private func resume(_ result: Result<URL, Error>) {
        guard !didResume else { return }
        didResume = true
        continuation?.resume(with: result)
        continuation = nil
    }
}

enum TranscriptionError: LocalizedError {
    case missingExecutable
    case missingModel
    case processFailed(String)
    case emptyResult(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            return "whisper-cli was not found. Install whisper-cpp with Homebrew."
        case .missingModel:
            return "Whisper model file was not found."
        case .processFailed(let output):
            return output.isEmpty ? "whisper-cli failed." : output
        case .emptyResult(let output):
            return output.isEmpty ? "Whisper returned empty text." : output
        }
    }
}
