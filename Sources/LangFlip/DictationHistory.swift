import Foundation

/// One completed dictation, shown in the Home screen's recent list.
struct DictationEntry: Identifiable, Codable {
    enum Status: String, Codable {
        case transcribed
        case failed
        case retrying
        case recovered
    }

    let id: UUID
    let text: String
    let date: Date
    /// Length of the recording in seconds, when known (older entries predate
    /// duration tracking and decode to nil). Drives WPM in Insights.
    let duration: Double?
    /// Name of the app the dictation was inserted into (the frontmost app when
    /// recording started). Older entries decode to nil. Drives the usage-by-app
    /// breakdown in Insights.
    let app: String?
    let status: Status
    let audioPath: String?
    let errorMessage: String?

    init(id: UUID = UUID(),
         text: String,
         date: Date = Date(),
         duration: Double? = nil,
         app: String? = nil,
         status: Status = .transcribed,
         audioPath: String? = nil,
         errorMessage: String? = nil) {
        self.id = id
        self.text = text
        self.date = date
        self.duration = duration
        self.app = app
        self.status = status
        self.audioPath = audioPath
        self.errorMessage = errorMessage
    }

    enum CodingKeys: String, CodingKey {
        case id, text, date, duration, app, status, audioPath, errorMessage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        date = try c.decode(Date.self, forKey: .date)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        app = try c.decodeIfPresent(String.self, forKey: .app)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .transcribed
        audioPath = try c.decodeIfPresent(String.self, forKey: .audioPath)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
    }

    /// Word count, split on whitespace.
    var wordCount: Int {
        guard isTranscribed else { return 0 }
        return text.split(whereSeparator: { $0.isWhitespace }).count
    }

    var isTranscribed: Bool { status == .transcribed || status == .recovered }
    var isFailed: Bool { status == .failed }
    var isRetrying: Bool { status == .retrying }
    var isRecovered: Bool { status == .recovered }
    var audioURL: URL? { audioPath.map(URL.init(fileURLWithPath:)) }
}

/// Persisted log of recent dictations. `VoiceDictationController` appends here
/// after a successful insert; the Home screen observes it to populate "Today".
/// Capped and stored in UserDefaults — this is a convenience history, not an
/// archive.
final class DictationHistory: ObservableObject {
    static let shared = DictationHistory()

    @Published private(set) var entries: [DictationEntry] = []

    private let key = "lf.dictationHistory"
    private let maxEntries = 500

    private init() { load() }

    func add(_ text: String, duration: Double? = nil, app: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = DictationEntry(text: trimmed, duration: duration, app: app)
        DispatchQueue.main.async {
            self.insert(entry)
        }
    }

    @discardableResult
    func recordFailure(audioURL: URL, duration: Double?, app: String?, error: String, replacing id: UUID? = nil) -> UUID {
        let entryID = id ?? UUID()
        let entry = DictationEntry(
            id: entryID,
            text: "Transcription failed",
            duration: duration,
            app: app,
            status: .failed,
            audioPath: audioURL.path,
            errorMessage: error
        )
        DispatchQueue.main.async {
            if let idx = self.entries.firstIndex(where: { $0.id == entryID }) {
                self.entries[idx] = entry
                self.save()
            } else {
                self.insert(entry)
            }
        }
        return entryID
    }

    /// Removes one entry and, if it kept a recording on disk (failed/recovered
    /// dictations do), deletes that `.wav` too so the file doesn't linger.
    func delete(_ entry: DictationEntry) {
        DispatchQueue.main.async {
            self.entries.removeAll { $0.id == entry.id }
            self.save()
            if let path = entry.audioPath {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    /// Removes every entry from a given day and deletes the recordings they kept.
    func delete(entriesOn day: Date) {
        DispatchQueue.main.async {
            let cal = Calendar.current
            let removed = self.entries.filter { cal.isDate($0.date, inSameDayAs: day) }
            guard !removed.isEmpty else { return }
            self.entries.removeAll { cal.isDate($0.date, inSameDayAs: day) }
            self.save()
            let paths = removed.compactMap(\.audioPath)
            if !paths.isEmpty {
                DispatchQueue.global(qos: .utility).async {
                    paths.forEach { try? FileManager.default.removeItem(atPath: $0) }
                }
            }
        }
    }

    /// Clears the whole list and reclaims every recording on disk — including
    /// orphans left by successful dictations from before audio cleanup existed.
    func deleteAll() {
        DispatchQueue.main.async {
            self.entries.removeAll()
            self.save()
        }
        // Reclaiming the recordings is disk I/O — keep it off the main thread.
        DispatchQueue.global(qos: .utility).async {
            VoiceRecorder.purgeAllRecordings()
        }
    }

    func markRetrying(id: UUID) {
        DispatchQueue.main.async {
            guard let idx = self.entries.firstIndex(where: { $0.id == id }) else { return }
            let previous = self.entries[idx]
            self.entries[idx] = DictationEntry(
                id: previous.id,
                text: "Retrying transcription",
                date: previous.date,
                duration: previous.duration,
                app: previous.app,
                status: .retrying,
                audioPath: previous.audioPath,
                errorMessage: nil
            )
            self.save()
        }
    }

    func replaceFailed(id: UUID, with text: String, duration: Double? = nil, app: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        DispatchQueue.main.async {
            if let idx = self.entries.firstIndex(where: { $0.id == id }) {
                let previous = self.entries[idx]
                self.entries[idx] = DictationEntry(
                    id: previous.id,
                    text: trimmed,
                    date: previous.date,
                    duration: duration ?? previous.duration,
                    app: app ?? previous.app,
                    status: .recovered,
                    audioPath: previous.audioPath
                )
                self.save()
            } else {
                self.insert(DictationEntry(text: trimmed, duration: duration, app: app))
            }
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([DictationEntry].self, from: data)
        else { return }
        var normalizedInterruptedRetry = false
        entries = decoded.map { entry in
            guard entry.isRetrying else { return entry }
            normalizedInterruptedRetry = true
            return DictationEntry(
                id: entry.id,
                text: "Transcription failed",
                date: entry.date,
                duration: entry.duration,
                app: entry.app,
                status: .failed,
                audioPath: entry.audioPath,
                errorMessage: "The previous retry was interrupted."
            )
        }
        if normalizedInterruptedRetry {
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func insert(_ entry: DictationEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        save()
    }
}
