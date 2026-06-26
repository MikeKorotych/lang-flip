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

    @Published private(set) var entries: [OCRHistoryEntry] = []

    private let key = "lf.ocrHistory"
    private let maxEntries = 300

    private init() { load() }

    func add(_ text: String) {
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

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([OCRHistoryEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
