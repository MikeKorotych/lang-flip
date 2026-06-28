import Foundation

struct TTSHistoryEntry: Identifiable, Codable {
    let id: UUID
    let text: String
    let date: Date
    let audioPath: String
    let model: String?
    let voice: String?

    init(id: UUID = UUID(),
         text: String,
         date: Date = Date(),
         audioURL: URL,
         model: String? = nil,
         voice: String? = nil) {
        self.id = id
        self.text = text
        self.date = date
        self.audioPath = audioURL.path
        self.model = model
        self.voice = voice
    }

    var audioURL: URL { URL(fileURLWithPath: audioPath) }
    var fileExists: Bool { FileManager.default.fileExists(atPath: audioPath) }

    var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

final class TTSHistory: ObservableObject {
    static let shared = TTSHistory()

    @Published private(set) var entries: [TTSHistoryEntry] = []

    private let key = "lf.ttsHistory"
    private let maxEntries = 200

    private init() { load() }

    func add(text: String, audioURL: URL, model: String? = nil, voice: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = TTSHistoryEntry(text: trimmed, audioURL: audioURL, model: model, voice: voice)
        DispatchQueue.main.async {
            self.entries.insert(entry, at: 0)
            if self.entries.count > self.maxEntries {
                self.entries.removeLast(self.entries.count - self.maxEntries)
            }
            self.save()
        }
    }

    func delete(_ entry: TTSHistoryEntry, removeFile: Bool = true) {
        DispatchQueue.main.async {
            self.entries.removeAll { $0.id == entry.id }
            self.save()
            if removeFile {
                try? FileManager.default.removeItem(at: entry.audioURL)
            }
        }
    }

    func delete(entriesOn day: Date) {
        DispatchQueue.main.async {
            let cal = Calendar.current
            let removed = self.entries.filter { cal.isDate($0.date, inSameDayAs: day) }
            guard !removed.isEmpty else { return }
            self.entries.removeAll { cal.isDate($0.date, inSameDayAs: day) }
            self.save()
            let urls = removed.map(\.audioURL)
            DispatchQueue.global(qos: .utility).async {
                urls.forEach { try? FileManager.default.removeItem(at: $0) }
            }
        }
    }

    func deleteAll() {
        DispatchQueue.main.async {
            let urls = self.entries.map(\.audioURL)
            self.entries.removeAll()
            self.save()
            DispatchQueue.global(qos: .utility).async {
                urls.forEach { try? FileManager.default.removeItem(at: $0) }
            }
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([TTSHistoryEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
