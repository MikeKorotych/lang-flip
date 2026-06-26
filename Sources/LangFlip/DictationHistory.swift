import Foundation

/// One completed dictation, shown in the Home screen's recent list.
struct DictationEntry: Identifiable, Codable {
    enum Status: String, Codable {
        case transcribed
        case failed
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

    var isTranscribed: Bool { status == .transcribed }
    var isFailed: Bool { status == .failed }
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
                    app: app ?? previous.app
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
        entries = decoded
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
