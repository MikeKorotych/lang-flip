import Foundation

/// One completed dictation, shown in the Home screen's recent list.
struct DictationEntry: Identifiable, Codable {
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

    init(text: String, date: Date, duration: Double? = nil, app: String? = nil) {
        self.id = UUID()
        self.text = text
        self.date = date
        self.duration = duration
        self.app = app
    }

    /// Word count, split on whitespace.
    var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
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
        let entry = DictationEntry(text: trimmed, date: Date(), duration: duration, app: app)
        DispatchQueue.main.async {
            self.entries.insert(entry, at: 0)
            if self.entries.count > self.maxEntries {
                self.entries.removeLast(self.entries.count - self.maxEntries)
            }
            self.save()
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
}
