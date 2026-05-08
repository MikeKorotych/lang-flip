import Foundation

/// Catches the two most common UK ↔ RU character mix-ups: a single wrong
/// letter sneaks into an otherwise correct word because the user briefly
/// had the other layout on, or because the corresponding key on the wrong
/// keyboard is right next to the intended one.
///
/// Pairs we correct (case-preserving):
///
///   ы (RU only)  ↔  і (UK only)
///   э (RU only)  ↔  є (UK only)
///
/// Examples:
///
///   "ы"            → "і"           (single misfire, swap layout to UK)
///   "пыдтримую"    → "підтримую"   (Ukrainian word with one Russian letter)
///   "зашіть"       → "зашыть"      (Russian word with one Ukrainian letter)
///   "єто"          → "это"         (Russian word with one Ukrainian letter)
///   "эдиний"       → "єдиний"      (Ukrainian word with one Russian letter)
///
/// Confidence is dictionary-based: we only suggest the swap if the
/// substituted form is in the target language's dictionary. Real Russian
/// words containing "ы" stay untouched because their UK equivalent isn't
/// a word, and vice versa.
enum CrossLayoutFix {

    struct Correction {
        let corrected: String
        let target: Layout
    }

    /// Pairs of letters that swap between the layouts. Each entry is
    /// (Russian-only letter, Ukrainian-only letter); both lower-case.
    private static let pairs: [(ru: Character, uk: Character)] = [
        ("ы", "і"),
        ("э", "є"),
    ]

    /// Letters that exist in *only* the Russian alphabet (not Ukrainian).
    private static let ruOnlyLetters: Set<Character> = ["ы", "э", "ё", "ъ"]

    /// Letters that exist in *only* the Ukrainian alphabet (not Russian).
    private static let ukOnlyLetters: Set<Character> = ["і", "є", "ї", "ґ"]

    private static let ukAlphabet: Set<Character> = Set("абвгґдеєжзиіїйклмнопрстуфхцчшщьюя'-")
    private static let ruAlphabet: Set<Character> = Set("абвгдеёжзийклмнопрстуфхцчшщъыьэюя-")

    /// Returns the corrected word and target layout, or nil if no swap
    /// applies. Caller is responsible for posting the rewrite + layout
    /// switch to the focused app.
    static func correction(for word: String, autoFlip: AutoFlip = .shared) -> Correction? {
        guard !word.isEmpty else { return nil }
        guard word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }) else { return nil }

        let lower = word.lowercased()
        let chars = Array(lower)

        // Decide direction by which side's exclusive letters appear. If
        // both sides' exclusive letters are present, the word is
        // genuinely mixed and we don't touch it.
        let hasRuExclusive = chars.contains { ruOnlyLetters.contains($0) }
        let hasUkExclusive = chars.contains { ukOnlyLetters.contains($0) }
        guard hasRuExclusive != hasUkExclusive else { return nil }

        if hasRuExclusive {
            // Word reads as Russian but might be a Ukrainian word with
            // one ы / э slip. Substitute toward UK.
            guard let candidate = substitute(word, mode: .ruToUk) else { return nil }
            // After substitution every char must be a valid UK letter.
            guard candidate.lowercased().allSatisfy({ ukAlphabet.contains($0) }) else { return nil }
            // Don't bother proposing a fix when the substitution is a no-op.
            guard candidate != word else { return nil }
            // Only accept if the result is a real Ukrainian word.
            guard autoFlip.isKnownWord(candidate.lowercased()) else { return nil }
            return Correction(corrected: candidate, target: .uk)
        } else {
            // Mirror: UK-exclusive letters → try Russian dictionary.
            guard let candidate = substitute(word, mode: .ukToRu) else { return nil }
            guard candidate.lowercased().allSatisfy({ ruAlphabet.contains($0) }) else { return nil }
            guard candidate != word else { return nil }
            guard autoFlip.isKnownWord(candidate.lowercased()) else { return nil }
            return Correction(corrected: candidate, target: .ru)
        }
    }

    /// Per-character pair substitution. Preserves the case of the
    /// original letter at each position.
    private enum SubstitutionMode { case ruToUk, ukToRu }

    private static func substitute(_ word: String, mode: SubstitutionMode) -> String? {
        var out = ""
        out.reserveCapacity(word.count)
        for ch in word {
            let lower = Character(String(ch).lowercased())
            let isUpper = ch.isUppercase
            if let mapped = mappedChar(for: lower, mode: mode) {
                out.append(isUpper ? Character(String(mapped).uppercased()) : mapped)
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private static func mappedChar(for lower: Character, mode: SubstitutionMode) -> Character? {
        switch mode {
        case .ruToUk:
            return pairs.first(where: { $0.ru == lower })?.uk
        case .ukToRu:
            return pairs.first(where: { $0.uk == lower })?.ru
        }
    }
}
