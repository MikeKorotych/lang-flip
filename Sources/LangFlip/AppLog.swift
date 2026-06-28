import Foundation

enum AppLog {
    /// Serializes writes (and rotation) so concurrent callers can't interleave
    /// or race the rotate-then-append sequence.
    private static let queue = DispatchQueue(label: "com.sayful.applog")

    /// Roll the log over once it reaches this size, keeping a single previous
    /// generation. Bounds disk use at ~2x this without losing recent history.
    private static let maxBytes: UInt64 = 2 * 1024 * 1024

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Sayful", isDirectory: true)
    }
    static var fileURL: URL { directory.appendingPathComponent("Sayful.log") }
    private static var rotatedURL: URL { directory.appendingPathComponent("Sayful.1.log") }

    static func write(_ message: String) {
        let line = "lang-flip: \(message)\n"
        let data = Data(line.utf8)
        FileHandle.standardError.write(data)

        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            rotateIfNeeded()
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: data)
            }
        }
    }

    /// Moves the current log aside (replacing any previous generation) once it
    /// grows past `maxBytes`. Must run on `queue`.
    private static func rotateIfNeeded() {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        guard size >= maxBytes else { return }
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: fileURL, to: rotatedURL)
    }

    /// Recent log text (previous generation + current), capped so the in-app
    /// "Share logs" action never hands off an unbounded blob. Returns the tail
    /// when the combined size exceeds `cap`.
    static func recentLogText(maxBytes cap: Int = 256 * 1024) -> String {
        queue.sync {
            let older = (try? String(contentsOf: rotatedURL, encoding: .utf8)) ?? ""
            let current = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            let combined = older + current
            guard combined.utf8.count > cap else { return combined }
            return "…(truncated)…\n" + String(combined.suffix(cap))
        }
    }
}
