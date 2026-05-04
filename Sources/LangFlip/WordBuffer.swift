import Foundation

/// Holds the characters typed since the last word boundary.
/// Boundaries: whitespace, newline, tab, and common punctuation that ends words.
final class WordBuffer {
    private(set) var current: String = ""

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
    /// Useful for auto-flip checks at word boundaries.
    func feedReturningCompleted(_ s: String) -> String? {
        var completed: String?
        for ch in s {
            if Self.boundary.contains(ch) {
                if !current.isEmpty && completed == nil {
                    completed = current
                }
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(ch)
            }
        }
        return completed
    }

    func backspace() {
        if !current.isEmpty { current.removeLast() }
    }

    func reset() {
        current.removeAll(keepingCapacity: true)
    }
}
