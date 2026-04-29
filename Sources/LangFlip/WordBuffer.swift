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

    func backspace() {
        if !current.isEmpty { current.removeLast() }
    }

    func reset() {
        current.removeAll(keepingCapacity: true)
    }
}
