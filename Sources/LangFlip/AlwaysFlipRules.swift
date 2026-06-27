import Foundation

/// User-managed rules that force a specific wrong-layout token to flip to a
/// chosen target language. This is intentionally tiny and deterministic: it
/// runs before dictionary scoring, so common personal misses can work even
/// while the larger dictionaries are still loading.
final class AlwaysFlipRules {
    static let shared = AlwaysFlipRules()

    struct Rule: Hashable, Identifiable {
        let word: String
        let target: Layout

        var id: String { "\(word)|\(target.rawValue)" }
        var storageValue: String { id }
    }

    private static let rulesKey = "lf.alwaysFlipRules"
    private let defaults = UserDefaults.standard
    private let lock = NSLock()
    private var storedRules: [Rule]

    private init() {
        let saved = defaults.array(forKey: Self.rulesKey) as? [String] ?? []
        storedRules = saved.compactMap(Self.decode)
    }

    var rules: [Rule] {
        lock.lock()
        defer { lock.unlock() }
        return storedRules
    }

    func target(for word: String, currentLayout: Layout) -> Layout? {
        let trimmed = Self.normalized(word)
        guard !trimmed.isEmpty else { return nil }
        lock.lock()
        let match = storedRules.first { $0.word == trimmed && $0.target != currentLayout }
        lock.unlock()
        return match?.target
    }

    func add(word: String, target: Layout) {
        let trimmed = Self.normalized(word)
        guard !trimmed.isEmpty else { return }
        let rule = Rule(word: trimmed, target: target)
        lock.lock()
        if !storedRules.contains(rule) {
            storedRules.append(rule)
            storedRules.sort { lhs, rhs in
                lhs.word == rhs.word ? lhs.target.rawValue < rhs.target.rawValue : lhs.word < rhs.word
            }
            saveLocked()
        }
        lock.unlock()
    }

    func remove(_ rule: Rule) {
        lock.lock()
        if let index = storedRules.firstIndex(of: rule) {
            storedRules.remove(at: index)
            saveLocked()
        }
        lock.unlock()
    }

    func clear() {
        lock.lock()
        storedRules.removeAll()
        defaults.removeObject(forKey: Self.rulesKey)
        lock.unlock()
    }

    private func saveLocked() {
        defaults.set(storedRules.map(\.storageValue), forKey: Self.rulesKey)
    }

    /// Trim only — case is preserved so rules are case-sensitive (a rule for
    /// "Привет" flips "Привет" but not "привет", and the entered casing sticks).
    private static func normalized(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decode(_ raw: String) -> Rule? {
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              !parts[0].isEmpty,
              let target = Layout(rawValue: parts[1])
        else {
            return nil
        }
        return Rule(word: parts[0], target: target)
    }
}
