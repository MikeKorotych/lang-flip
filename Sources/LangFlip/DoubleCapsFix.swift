import Foundation

/// Sticky-shift correction. Catches the classic fast-typing mistake where
/// the user holds Shift a beat too long and the second character of a word
/// also lands as uppercase: "WOrld", "ПРивет", "HEllo".
///
/// Heuristic:
///   1. Word ≥ 3 letters, all letters (no digits/punctuation).
///   2. First two chars uppercase, rest lowercase.
///   3. The corrected form (only the SECOND char lowercased) is a known
///      dictionary word — protects intentional acronyms like "OAuth",
///      "TLAn", "PDFs" that match the pattern but aren't typos.
enum DoubleCapsFix {

    /// Returns the corrected word if `word` looks like a sticky-shift typo,
    /// nil if it should be left alone.
    static func correction(for word: String) -> String? {
        let chars = Array(word)
        guard chars.count >= 3 else { return nil }
        guard chars.allSatisfy({ $0.isLetter }) else { return nil }
        guard chars[0].isUppercase, chars[1].isUppercase else { return nil }
        for i in 2..<chars.count where !chars[i].isLowercase { return nil }

        var fixed = ""
        fixed.append(chars[0])
        fixed.append(Character(String(chars[1]).lowercased()))
        fixed.append(contentsOf: chars[2...])

        // Confirm it lands on a real word; otherwise the user probably meant
        // the all-caps prefix (acronym, brand). Better to leave alone than
        // mangle.
        guard AutoFlip.shared.isKnownWord(fixed.lowercased()) else { return nil }
        return fixed
    }
}
