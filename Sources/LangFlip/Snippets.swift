import Foundation

/// A text snippet: a spoken/typed trigger phrase that expands to longer text.
struct Snippet: Identifiable, Codable, Equatable {
    let id: UUID
    var trigger: String
    var expansion: String

    init(id: UUID = UUID(), trigger: String, expansion: String) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
    }
}

/// Persisted snippets + the expansion engine. `VoiceDictationController` runs a
/// dictation's transcript through `expand` before inserting, so triggers are
/// replaced automatically with no extra step.
final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()

    @Published private(set) var snippets: [Snippet] = []

    private let key = "lf.snippets"

    private init() { load() }

    func add(trigger: String, expansion: String) {
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        snippets.append(Snippet(trigger: t, expansion: expansion))
        save()
    }

    func update(_ snippet: Snippet) {
        guard let idx = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[idx] = snippet
        save()
    }

    func remove(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        save()
    }

    /// Replace every snippet trigger found in `text` with its expansion.
    /// Triggers match whole words/phrases (bounded by non-letter/digit),
    /// case-insensitively. Longer triggers are applied first so they win over
    /// shorter overlapping ones.
    func expand(_ text: String) -> String {
        var result = text
        for snippet in snippets.sorted(by: { $0.trigger.count > $1.trigger.count }) {
            let trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty else { continue }
            let pattern = "(?<![\\p{L}\\p{N}])"
                + NSRegularExpression.escapedPattern(for: trigger)
                + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: snippet.expansion)
            )
        }
        return result
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Snippet].self, from: data)
        else { return }
        snippets = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(snippets) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
