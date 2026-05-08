import Foundation

/// In-progress and most-recent-completed sentence tracker, sister type to
/// WordBuffer. Used by the AI grammar-check feature to know what counts as
/// "the last sentence" without us having to read text out of the focused
/// app via Accessibility / clipboard hijacking.
///
/// "Sentence end" is `.`, `!`, `?`, or newline. When one of those characters
/// is typed, the in-progress text becomes the previous sentence and a new
/// one starts.
final class SentenceBuffer {
    private(set) var current: String = ""
    private(set) var previous: String = ""

    private static let sentenceEnd: Set<Character> = [".", "!", "?", "\n"]

    /// Append every typed character. Non-text events (modifier keys,
    /// arrow keys, function keys) should not call this.
    func feed(_ s: String) {
        for ch in s {
            current.append(ch)
            if Self.sentenceEnd.contains(ch) {
                previous = current
                current = ""
            }
        }
    }

    /// Consume one Backspace from the end of the in-progress sentence.
    /// Doesn't reach into the previous sentence — once a sentence ends
    /// it's frozen.
    func backspace() {
        if !current.isEmpty { current.removeLast() }
    }

    /// What the user would call "the last sentence I typed":
    ///   - the in-progress text if it has any letters,
    ///   - otherwise the previously-completed sentence.
    /// Returns nil if there's nothing to operate on.
    var mostRecentSentence: String? {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return current }
        let prevTrimmed = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prevTrimmed.isEmpty { return previous }
        return nil
    }

    /// Replace the in-progress sentence with `rewritten`. Used by grammar
    /// fix after the AI returns a corrected version.
    func replaceCurrent(with rewritten: String) {
        current = rewritten
    }

    /// Replace the previous sentence (in case grammar check rewrote it
    /// because the in-progress one was empty).
    func replacePrevious(with rewritten: String) {
        previous = rewritten
    }

    func reset() {
        current.removeAll(keepingCapacity: true)
        previous.removeAll(keepingCapacity: true)
    }
}
