import Foundation

/// Holds the characters typed since the last word boundary.
/// Boundaries: whitespace, newline, tab, and common punctuation that ends words.
final class WordBuffer {
    private(set) var current: String = ""

    /// Most recent completed words, oldest → newest. Used by the AI
    /// assistant to give Foundation Models / LMs a few words of context
    /// when it's deciding whether a candidate flip makes sense.
    private(set) var recentHistory: [String] = []
    private static let recentHistoryCap = 8

    private static let boundary: Set<Character> = [
        " ", "\t", "\n", "\r",
        ",", ".", ";", ":", "!", "?",
        "(", ")", "[", "]", "{", "}",
        "\"", "'", "`", "/", "\\", "|", "—", "–"
    ]

    func feed(_ s: String) {
        for ch in s {
            if Self.boundary.contains(ch) {
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(ch)
            }
        }
    }

    /// Like `feed`, but if a boundary character is hit, returns the word that
    /// was just completed (the buffer's contents before the boundary).
    /// Useful for auto-flip checks at word boundaries. Completed words
    /// also accumulate in `recentHistory` (capped) for AI context.
    func feedReturningCompleted(_ s: String) -> String? {
        var completed: String?
        for ch in s {
            if Self.boundary.contains(ch) {
                if !current.isEmpty {
                    if completed == nil {
                        completed = current
                    }
                    appendToHistory(current)
                }
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(ch)
            }
        }
        return completed
    }

    private func appendToHistory(_ word: String) {
        recentHistory.append(word)
        if recentHistory.count > Self.recentHistoryCap {
            recentHistory.removeFirst(recentHistory.count - Self.recentHistoryCap)
        }
    }

    /// Recent completed words joined with spaces, suitable for an AI
    /// prompt. Empty when the user just started typing.
    func recentContext() -> String {
        return recentHistory.joined(separator: " ")
    }

    func backspace() {
        if !current.isEmpty { current.removeLast() }
    }

    func reset() {
        current.removeAll(keepingCapacity: true)
    }
}
