import Foundation

/// Caramba-style learning: when the user disagrees with an auto-flip and
/// backspaces it away, remember the original word and never auto-flip it
/// again. Sidesteps the dictionary-coverage problem — the dict can be
/// imperfect because users teach the app their jargon.
///
/// Two signal strengths:
///   - **Loose** (1+ backspace within 2 s after a flip): add the original
///     word to the local exception list. AutoFlip will ignore it next time.
///   - **Strong** (the user erased the entire converted word + the trailing
///     space): also physically roll the flip back — switch the input
///     source back to the source layout and re-type the original.
final class BackspaceLearner {
    static let shared = BackspaceLearner()

    /// How long we watch for a disagreement signal after an auto-flip.
    private static let watchWindow: TimeInterval = 2.0

    /// UserDefaults key for the persisted exception set.
    private static let exceptionsKey = "lf.flipExceptions"

    /// State held only between an auto-flip and the user's next move.
    private struct PendingFlip {
        let originalWord: String
        let convertedWord: String
        let sourceLayout: Layout
        let targetLayout: Layout
        let timestamp: Date
        var backspaceCount: Int
        var addedException: Bool
    }

    /// Where the rollback handler will need to act.
    struct RollbackRequest {
        let originalWord: String
        let sourceLayout: Layout
    }

    private var pending: PendingFlip?
    private(set) var exceptions: Set<String>
    private let defaults = UserDefaults.standard

    private init() {
        let saved = defaults.array(forKey: Self.exceptionsKey) as? [String] ?? []
        exceptions = Set(saved.map { $0.lowercased() })
    }

    /// Called from EventTap right after a successful auto-flip — starts
    /// the disagreement-watch window.
    func recordFlip(original: String, converted: String, source: Layout, target: Layout) {
        pending = PendingFlip(
            originalWord: original,
            convertedWord: converted,
            sourceLayout: source,
            targetLayout: target,
            timestamp: Date(),
            backspaceCount: 0,
            addedException: false
        )
    }

    /// Call on every Backspace key event. Returns a `RollbackRequest` only
    /// when the user has erased the entire flipped word (strong signal).
    /// On the first backspace inside the window the word is silently added
    /// to the exception list.
    func handleBackspace() -> RollbackRequest? {
        guard var p = pending else { return nil }

        if Date().timeIntervalSince(p.timestamp) > Self.watchWindow {
            pending = nil
            return nil
        }

        p.backspaceCount += 1

        // Loose signal: even one backspace within the window means "I didn't
        // want that flip" — remember the word so it isn't auto-flipped again.
        if !p.addedException {
            addException(p.originalWord)
            p.addedException = true
        }

        // Strong signal: erased the entire converted word plus the trailing
        // space we added → roll the flip back physically.
        if p.backspaceCount >= p.convertedWord.count + 1 {
            pending = nil
            return RollbackRequest(
                originalWord: p.originalWord,
                sourceLayout: p.sourceLayout
            )
        }

        pending = p
        return nil
    }

    /// Call on any non-Backspace keystroke. The user accepted the flip (or
    /// moved on) — stop watching.
    func cancelPending() {
        pending = nil
    }

    /// True if `word` was rejected by the user previously and should never
    /// be auto-flipped again. Case-insensitive.
    func isExcluded(_ word: String) -> Bool {
        exceptions.contains(word.lowercased())
    }

    /// Wipe the learned exception list. User-facing — exposed in the
    /// menubar for the rare case where the user wants a fresh start.
    func clearExceptions() {
        exceptions.removeAll()
        defaults.removeObject(forKey: Self.exceptionsKey)
    }

    /// Add an exception manually from Preferences. Useful for product
    /// names, nicknames, commands, and other words the app should never
    /// auto-flip.
    func addException(_ word: String) {
        let lower = word.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return }
        if exceptions.insert(lower).inserted {
            saveExceptions()
        }
    }

    func removeException(_ word: String) {
        let lower = word.lowercased()
        if exceptions.remove(lower) != nil {
            saveExceptions()
        }
    }

    private func saveExceptions() {
        defaults.set(Array(exceptions).sorted(), forKey: Self.exceptionsKey)
    }
}
