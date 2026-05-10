import Foundation

enum QwenASRTranscriber {
    struct Availability {
        let pythonURL: URL?
        let modelDirectory: URL?

        var isReady: Bool {
            pythonURL != nil && modelDirectory != nil
        }
    }

    static let runtimeDirectory = URL(
        fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/LangFlip/Runtimes/qwen-asr-venv",
        isDirectory: true
    )

    static var pythonURL: URL {
        runtimeDirectory.appendingPathComponent("bin/python")
    }

    static func availability() -> Availability {
        Availability(
            pythonURL: FileManager.default.isExecutableFile(atPath: pythonURL.path) ? pythonURL : nil,
            modelDirectory: WhisperTranscriber.QwenASR.isInstalled ? WhisperTranscriber.QwenASR.directory : nil
        )
    }

    static func transcribe(audioURL: URL, language: String) async throws -> String {
        let availability = availability()
        guard let pythonURL = availability.pythonURL else {
            throw QwenASRError.missingRuntime
        }
        guard let modelDirectory = availability.modelDirectory else {
            throw QwenASRError.missingModel
        }

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = pythonURL
            process.arguments = [
                "-c",
                pythonScript,
                modelDirectory.path,
                audioURL.path,
                qwenLanguageName(for: language)
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
                throw QwenASRError.processFailed(errorOutput.isEmpty ? output : errorOutput)
            }
            guard !output.isEmpty else {
                throw QwenASRError.emptyResult(errorOutput)
            }
            return output
        }.value
    }

    private static func qwenLanguageName(for language: String) -> String {
        switch language {
        case "en": return "English"
        case "ru": return "Russian"
        default: return "auto"
        }
    }

    private static let pythonScript = #"""
import sys
import time
import torch
from qwen_asr import Qwen3ASRModel

model_dir = sys.argv[1]
audio = sys.argv[2]
language_arg = sys.argv[3]
language = None if language_arg == "auto" else language_arg

model = Qwen3ASRModel.from_pretrained(
    model_dir,
    dtype=torch.float16,
    device_map="mps" if torch.backends.mps.is_available() else "cpu",
    max_inference_batch_size=1,
    max_new_tokens=512,
)
results = model.transcribe(audio=audio, language=language)
print(results[0].text.strip())
"""#
}

enum QwenASRError: LocalizedError {
    case missingRuntime
    case missingModel
    case processFailed(String)
    case emptyResult(String)

    var errorDescription: String? {
        switch self {
        case .missingRuntime:
            return "Qwen ASR runtime is not installed."
        case .missingModel:
            return "Qwen3-ASR model files are not installed."
        case .processFailed(let output):
            return output.isEmpty ? "Qwen ASR failed." : output
        case .emptyResult(let output):
            return output.isEmpty ? "Qwen ASR returned empty text." : output
        }
    }
}
