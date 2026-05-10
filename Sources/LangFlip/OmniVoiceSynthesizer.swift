import AppKit
import Foundation

final class OmniVoiceSynthesizer {
    static let shared = OmniVoiceSynthesizer()

    struct Availability {
        let executableURL: URL?
        let ffmpegURL: URL?
        let modelCacheExists: Bool

        var isReady: Bool {
            executableURL != nil && ffmpegURL != nil
        }
    }

    private var generationProcess: Process?
    private var playbackProcess: Process?
    private(set) var lastOutputURL: URL?

    private init() {}

    static let runtimeDirectory = URL(
        fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/LangFlip/Runtimes/omnivoice-venv",
        isDirectory: true
    )

    static var executableURL: URL {
        runtimeDirectory.appendingPathComponent("bin/omnivoice-infer")
    }

    static var outputDirectory: URL {
        URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/LangFlip/TTS", isDirectory: true)
    }

    static var modelCacheDirectory: URL {
        URL(fileURLWithPath: "\(NSHomeDirectory())/.cache/huggingface/hub/models--k2-fsa--OmniVoice", isDirectory: true)
    }

    var isSpeaking: Bool {
        generationProcess?.isRunning == true || playbackProcess?.isRunning == true
    }

    static func availability() -> Availability {
        Availability(
            executableURL: FileManager.default.isExecutableFile(atPath: executableURL.path) ? executableURL : nil,
            ffmpegURL: executable(named: "ffmpeg"),
            modelCacheExists: FileManager.default.fileExists(atPath: modelCacheDirectory.path)
        )
    }

    @discardableResult
    func speak(_ text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        stop()

        Task {
            do {
                let url = try await generate(text: clean)
                await MainActor.run {
                    self.play(url)
                }
            } catch {
                await MainActor.run {
                    Notifications.show(title: "OmniVoice failed", body: error.localizedDescription)
                }
            }
        }
        return true
    }

    func generate(text: String) async throws -> URL {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw OmniVoiceError.emptyText }
        guard let executableURL = Self.availability().executableURL else {
            throw OmniVoiceError.missingRuntime
        }

        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        let outputURL = Self.outputDirectory
            .appendingPathComponent("omnivoice-\(Int(Date().timeIntervalSince1970)).wav")

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executableURL
            process.arguments = Self.arguments(text: clean, outputURL: outputURL)
            process.environment = Self.processEnvironment()
            process.standardOutput = pipe
            process.standardError = pipe

            await MainActor.run {
                self.generationProcess = process
            }
            defer {
                Task { @MainActor in self.generationProcess = nil }
            }

            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw OmniVoiceError.processFailed(output)
            }
            guard FileManager.default.fileExists(atPath: outputURL.path) else {
                throw OmniVoiceError.noOutput
            }
            await MainActor.run {
                self.lastOutputURL = outputURL
            }
            return outputURL
        }.value
    }

    func play(_ url: URL) {
        playbackProcess?.terminate()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [url.path]
        do {
            try process.run()
            playbackProcess = process
        } catch {
            Notifications.show(title: "Audio playback failed", body: error.localizedDescription)
        }
    }

    func stop() {
        if generationProcess?.isRunning == true {
            generationProcess?.terminate()
        }
        if playbackProcess?.isRunning == true {
            playbackProcess?.terminate()
        }
        generationProcess = nil
        playbackProcess = nil
    }

    private static func arguments(text: String, outputURL: URL) -> [String] {
        let settings = Settings.shared
        var args = [
            "--model", "k2-fsa/OmniVoice",
            "--text", text,
            "--output", outputURL.path,
            "--device", "mps",
            "--num_step", "\(settings.omniVoiceNumSteps)",
            "--guidance_scale", String(format: "%.2f", settings.omniVoiceGuidanceScale),
            "--denoise", settings.omniVoiceDenoise ? "true" : "false",
            "--postprocess_output", settings.omniVoicePostprocessOutput ? "true" : "false",
            "--t_shift", String(format: "%.2f", settings.omniVoiceTShift),
            "--layer_penalty_factor", String(format: "%.2f", settings.omniVoiceLayerPenaltyFactor),
            "--position_temperature", String(format: "%.2f", settings.omniVoicePositionTemperature),
            "--class_temperature", String(format: "%.2f", settings.omniVoiceClassTemperature)
        ]
        if settings.omniVoiceDuration > 0 {
            args += ["--duration", String(format: "%.2f", settings.omniVoiceDuration)]
        } else if abs(settings.omniVoiceSpeed - 1.0) > 0.001 {
            args += ["--speed", String(format: "%.2f", settings.omniVoiceSpeed)]
        }
        let referenceAudioPath = settings.omniVoiceReferenceAudioPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !referenceAudioPath.isEmpty,
           FileManager.default.fileExists(atPath: referenceAudioPath) {
            args += ["--ref_audio", referenceAudioPath]
            let referenceText = settings.omniVoiceReferenceText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !referenceText.isEmpty {
                args += ["--ref_text", referenceText]
            }
        }
        if let language = languageValue(for: text) {
            args += ["--language", language]
        }
        let instruct = styleInstruction()
        if !instruct.isEmpty {
            args += ["--instruct", instruct]
        }
        return args
    }

    private static func languageValue(for text: String) -> String? {
        let configured = Settings.shared.omniVoiceLanguage
        if let explicit = configured.cliValue {
            return explicit
        }
        if text.range(of: #"[іїєґІЇЄҐ]"#, options: .regularExpression) != nil {
            return "Ukrainian"
        }
        if text.range(of: #"[а-яА-ЯёЁ]"#, options: .regularExpression) != nil {
            return "Russian"
        }
        if text.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil {
            return "English"
        }
        return nil
    }

    private static func styleInstruction() -> String {
        let settings = Settings.shared
        var items = [
            settings.omniVoiceGender.rawValue,
            settings.omniVoiceAge.rawValue,
            settings.omniVoicePitch.rawValue,
            settings.omniVoiceAccent.rawValue
        ].filter { !$0.isEmpty }
        if settings.omniVoiceWhisper {
            items.append("whisper")
        }
        return items.joined(separator: ", ")
    }

    private static func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            existingPath
        ].joined(separator: ":")
        return environment
    }

    private static func executable(named name: String) -> URL? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

enum OmniVoiceError: LocalizedError {
    case emptyText
    case missingRuntime
    case processFailed(String)
    case noOutput

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "No text to speak."
        case .missingRuntime:
            return "OmniVoice runtime is not installed."
        case .processFailed(let output):
            return output.isEmpty ? "OmniVoice failed." : output
        case .noOutput:
            return "OmniVoice did not produce an audio file."
        }
    }
}
