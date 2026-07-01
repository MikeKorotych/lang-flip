import Foundation

struct OCRHistoryEntry: Identifiable, Codable {
    let id: UUID
    let text: String
    let date: Date

    init(id: UUID = UUID(), text: String, date: Date = Date()) {
        self.id = id
        self.text = text
        self.date = date
    }

    var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

final class OCRHistory: ObservableObject {
    static let shared = OCRHistory()
    static let storageKey = "lf.ocrHistory"

    @Published private(set) var entries: [OCRHistoryEntry] = []

    private let key = OCRHistory.storageKey
    private let maxEntries = 300

    private init() { load() }

    func add(_ text: String) {
        guard LocalContentPrivacy.retainsLocalContentHistory else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = OCRHistoryEntry(text: trimmed)
        DispatchQueue.main.async {
            self.entries.insert(entry, at: 0)
            if self.entries.count > self.maxEntries {
                self.entries.removeLast(self.entries.count - self.maxEntries)
            }
            self.save()
        }
    }

    func delete(_ entry: OCRHistoryEntry) {
        DispatchQueue.main.async {
            self.entries.removeAll { $0.id == entry.id }
            self.save()
        }
    }

    func delete(entriesOn day: Date) {
        DispatchQueue.main.async {
            let cal = Calendar.current
            self.entries.removeAll { cal.isDate($0.date, inSameDayAs: day) }
            self.save()
        }
    }

    func deleteAll() {
        DispatchQueue.main.async {
            self.entries.removeAll()
            self.save()
        }
    }

    private func load() {
        guard LocalContentPrivacy.retainsLocalContentHistory else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([OCRHistoryEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard LocalContentPrivacy.retainsLocalContentHistory else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
