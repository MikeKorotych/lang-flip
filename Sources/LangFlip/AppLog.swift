import Foundation

enum AppLog {
    static func write(_ message: String) {
        let line = "lang-flip: \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))

        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LangFlip", isDirectory: true)
        let url = dir.appendingPathComponent("LangFlip.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}
