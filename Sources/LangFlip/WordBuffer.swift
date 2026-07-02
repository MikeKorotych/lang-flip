import Foundation

/// Holds the characters typed since the last word boundary.
/// Auto-flip is intentionally evaluated on whitespace, not punctuation:
/// punctuation keys such as ";" can be real Cyrillic letters ("ж") when the
/// user is typing on the wrong layout. Completing only on space keeps words
/// like "nfr;t" together until they can be converted to "также".
final class WordBuffer {
    struct CompletedWord {
        let word: String
        let boundary: String
    }

    private(set) var current: String = ""
    private(set) var lastCompleted: CompletedWord?

    /// Most recent completed words, oldest → newest. Used by the AI
    /// assistant to give Foundation Models / LMs a few words of context
    /// when it's deciding whether a candidate flip makes sense.
    private(set) var recentHistory: [String] = []
    private static let recentHistoryCap = 8

    private static let completionBoundary: Set<Character> = [" "]
    private static let resetBoundary: Set<Character> = ["\t", "\n", "\r"]

    /// Punctuation that can trail a normal word but is not itself a physical
    /// letter in the supported Cyrillic layouts. When the user types
    /// "ghbdtn! ", we rewrite only "ghbdtn" and preserve "! " as the boundary.
    /// Characters like ";", ",", ".", "[" and "]" stay in the word because
    /// they map to Cyrillic letters on the same physical keys.
    private static let trailingPunctuation: Set<Character> = [
        ":", "!", "?",
        ")", "}",
        "\"", "`", "/", "\\", "|", "—", "–"
    ]

    func feed(_ s: String) {
        for ch in s {
            if Self.completionBoundary.contains(ch) || Self.resetBoundary.contains(ch) {
                current.removeAll(keepingCapacity: true)
                if Self.resetBoundary.contains(ch) {
                    lastCompleted = nil
                }
            } else {
                current.append(ch)
            }
        }
    }

    /// Like `feed`, but if a boundary character is hit, returns the word that
    /// was just completed (the buffer's contents before the boundary).
    /// Useful for auto-flip checks at word boundaries. Completed words
    /// also accumulate in `recentHistory` (capped) for AI context.
    func feedReturningCompleted(_ s: String) -> CompletedWord? {
        var completed: CompletedWord?
        for ch in s {
            if Self.completionBoundary.contains(ch) {
                if !current.isEmpty {
                    if let next = Self.completedWord(from: current, whitespace: String(ch)) {
                        if completed == nil {
                            completed = next
                        }
                        appendToHistory(next.word)
                        lastCompleted = next
                    }
                } else {
                    lastCompleted = nil
                }
                current.removeAll(keepingCapacity: true)
            } else if Self.resetBoundary.contains(ch) {
                current.removeAll(keepingCapacity: true)
                lastCompleted = nil
            } else {
                current.append(ch)
            }
        }
        return completed
    }

    private static func completedWord(from token: String, whitespace: String) -> CompletedWord? {
        var word = token
        var suffix = ""
        while let last = word.last, trailingPunctuation.contains(last) {
            suffix.insert(last, at: suffix.startIndex)
            word.removeLast()
        }
        guard !word.isEmpty else { return nil }
        return CompletedWord(word: word, boundary: suffix + whitespace)
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
        lastCompleted = nil
        if !current.isEmpty { current.removeLast() }
    }

    func replaceLastToken(word: String, boundary: String) {
        if boundary.isEmpty {
            current = word
            lastCompleted = nil
        } else {
            current.removeAll(keepingCapacity: true)
            lastCompleted = CompletedWord(word: word, boundary: boundary)
        }
    }

    func reset() {
        current.removeAll(keepingCapacity: true)
        lastCompleted = nil
    }
}
