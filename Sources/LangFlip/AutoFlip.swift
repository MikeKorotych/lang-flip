import Foundation

/// Decides whether a freshly-completed word was typed in the wrong layout
/// and, if so, what layout to flip it to.
///
/// Strategy:
///   - For each candidate target layout, convert the word to that layout.
///   - Score each variant: in-dictionary > looks-like-word > otherwise.
///   - If the best variant beats the original by a clear margin, flip.
final class AutoFlip {
    static let shared = AutoFlip()

    private let enWords: Set<String>
    private let ukCommon: Set<String>
    private let ruCommon: Set<String>

    private init() {
        // System English dictionary (preinstalled on macOS in /usr/share/dict/words).
        // If absent (chrooted env, customized macOS, etc.), auto-flip can still
        // work but loses its strongest "is this a real English word?" signal.
        let dictPath = "/usr/share/dict/words"
        if let raw = try? String(contentsOfFile: dictPath, encoding: .utf8) {
            enWords = Set(raw.split(separator: "\n").map { $0.lowercased() })
        } else {
            FileHandle.standardError.write(Data(
                "lang-flip: could not read \(dictPath); auto-flip will rely on heuristics for English.\n".utf8
            ))
            enWords = []
        }

        // UK / RU lists shipped as bundled resources (built by
        // Scripts/build-dicts.sh). If a file is missing — e.g. running from
        // outside the .app or from a fresh checkout where the script hasn't
        // been run — fall back to the much smaller embedded list so the
        // negative signal still works for the most common words.
        ukCommon = Self.loadResource(name: "uk-words", fallback: EmbeddedDicts.ukrainian)
        ruCommon = Self.loadResource(name: "ru-words", fallback: EmbeddedDicts.russian)
    }

    private static func loadResource(name: String, fallback: [String]) -> Set<String> {
        // Production .app bundle: the Makefile drops the txt files into
        // .app/Contents/Resources/Dictionaries/ so they don't need to live
        // inside an SPM-generated .bundle wrapper (which has no Info.plist
        // and therefore makes codesign refuse to sign the .app).
        if let url = Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Dictionaries"),
           let words = readWordList(at: url) {
            return words
        }
        // Dev runs (swift run / swift test): SPM resource bundle next to
        // the executable. Bundle.module finds it.
        if let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Dictionaries"),
           let words = readWordList(at: url) {
            return words
        }
        FileHandle.standardError.write(Data(
            "lang-flip: \(name).txt not bundled — using fallback (\(fallback.count) words). Run Scripts/build-dicts.sh to install the full list.\n".utf8
        ))
        return Set(fallback.map { $0.lowercased() })
    }

    private static func readWordList(at url: URL) -> Set<String>? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let words = raw.split(whereSeparator: { $0.isNewline })
        return Set(words.map { String($0) })
    }

    /// Returns target layout if we should auto-flip; nil otherwise.
    func suggestedFlip(for word: String, currentLayout: Layout) -> Layout? {
        // Skip very short tokens — high false-positive rate ("я", "is", "и").
        guard word.count >= 3 else { return nil }
        // Skip anything with digits or non-letter cruft.
        if word.contains(where: { $0.isNumber }) { return nil }
        // Words the user previously rejected via Backspace — never auto-flip.
        if BackspaceLearner.shared.isExcluded(word) { return nil }
        // High-entropy strings (passwords, tokens, hashes) — keep them as-is
        // even if a layout flip would produce dictionary chars.
        if looksLikePassword(word) { return nil }

        let lower = word.lowercased()
        let originalScore = score(lower, in: currentLayout)

        var bestLayout: Layout?
        var bestScore = originalScore

        for target in Layout.allCases where target != currentLayout {
            let converted = convert(lower, from: currentLayout, to: target)
            let s = score(converted, in: target)
            if s > bestScore {
                bestScore = s
                bestLayout = target
            }
        }

        // Require a clear win:
        //   - some target layout must score *higher* than the original
        //     (otherwise there's no reason to flip),
        //   - the target must be a real dictionary word (score 2),
        //   - the target must beat the original by at least one tier.
        //
        // Older logic required `originalScore == 0`, but that missed cases
        // like "руддщ" — the cyrillic gibberish has a vowel ("у") and so
        // passes the looksLikeCyrillic check (score 1), even though it's
        // clearly the result of typing English on a Ukrainian keyboard.
        // Real cyrillic words score 2 (in dict) and aren't affected by
        // this loosening — and any false positive that slips through can
        // be fixed permanently with a single Backspace thanks to
        // BackspaceLearner.
        guard let layout = bestLayout,
              bestScore >= 2,
              bestScore - originalScore >= 1
        else {
            return nil
        }
        return layout
    }

    /// True if `lowercased` is in any of our dictionaries. Used by
    /// DoubleCapsFix to confirm a sticky-shift correction would land on a
    /// real word rather than mangling an intentional acronym like "OAuth".
    func isKnownWord(_ lowercased: String) -> Bool {
        return enWords.contains(lowercased)
            || ukCommon.contains(lowercased)
            || ruCommon.contains(lowercased)
    }

    /// Per-language lookups, used by CrossLayoutFix to disambiguate
    /// words like "новій" that are real Ukrainian *and* whose RU
    /// substitution ("новый") is real Russian. The bare isKnownWord
    /// can't tell them apart.
    func isKnownInUk(_ lowercased: String) -> Bool {
        return ukCommon.contains(lowercased)
    }

    func isKnownInRu(_ lowercased: String) -> Bool {
        return ruCommon.contains(lowercased)
    }

    /// 2 = in dictionary, 1 = plausibly word-shaped, 0 = noise.
    private func score(_ word: String, in layout: Layout) -> Int {
        switch layout {
        case .en:
            return enWords.contains(word) ? 2 : (looksLikeEnglish(word) ? 1 : 0)
        case .uk:
            return ukCommon.contains(word) ? 2 : (looksLikeCyrillic(word, allowed: ukAlphabet) ? 1 : 0)
        case .ru:
            return ruCommon.contains(word) ? 2 : (looksLikeCyrillic(word, allowed: ruAlphabet) ? 1 : 0)
        }
    }

    // MARK: - Heuristics

    private let ukAlphabet: Set<Character> = Set("абвгґдеєжзиіїйклмнопрстуфхцчшщьюя'")
    private let ruAlphabet: Set<Character> = Set("абвгдеёжзийклмнопрстуфхцчшщъыьэюя")

    private func looksLikeEnglish(_ word: String) -> Bool {
        // All ASCII letters AND has at least one vowel AND no triple-same letter.
        let chars = Array(word)
        guard chars.allSatisfy({ $0.isLetter && $0.isASCII }) else { return false }
        let hasVowel = chars.contains(where: { "aeiouy".contains($0) })
        guard hasVowel else { return false }
        return !hasTripleRepeat(chars)
    }

    private func looksLikeCyrillic(_ word: String, allowed: Set<Character>) -> Bool {
        let chars = Array(word)
        guard chars.allSatisfy({ allowed.contains($0) }) else { return false }
        let hasVowel = chars.contains(where: { "аеєиіїоуюяыэё".contains($0) })
        guard hasVowel else { return false }
        return !hasTripleRepeat(chars)
    }

    private func hasTripleRepeat(_ chars: [Character]) -> Bool {
        guard chars.count >= 3 else { return false }
        for i in 0..<(chars.count - 2) where chars[i] == chars[i+1] && chars[i+1] == chars[i+2] {
            return true
        }
        return false
    }

    /// "This looks like a password / token / hash" heuristic.
    /// We never want to flip these even if a converted form would land
    /// in a dictionary by accident.
    ///
    /// Two cheap, high-precision rules — chosen so common prose words
    /// ("Hello", "Привіт", "John") stay below the bar but obvious
    /// credentials clear it:
    ///
    ///   1. Any "strong" special character (!@#$%^&*…) → password.
    ///      Normal text words don't contain these; passwords routinely
    ///      do. We deliberately exclude `.`, `,`, `'`, `-` because real
    ///      words and proper nouns can include them.
    ///
    ///   2. Long string with mixed case AND no vowels — typical of
    ///      randomly-generated tokens and hex hashes.
    ///
    /// Words containing digits are already short-circuited by the
    /// caller, so digits don't appear in this function.
    private func looksLikePassword(_ word: String) -> Bool {
        guard word.count >= 6 else { return false }

        let strongSpecials: Set<Character> = ["!", "@", "#", "$", "%", "^", "&", "*",
                                              "(", ")", "_", "+", "=", "{", "}",
                                              "[", "]", "\\", "|", ";", ":", "\"",
                                              "<", ">", "?", "/", "~", "`"]
        if word.contains(where: { strongSpecials.contains($0) }) { return true }

        let hasUpper = word.contains { $0.isUppercase }
        let hasLower = word.contains { $0.isLowercase }
        let isMixedCase = hasUpper && hasLower

        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y",
                                      "а", "е", "и", "і", "ї", "о", "у", "ю", "я",
                                      "ы", "э", "ё", "є"]
        let hasVowel = word.lowercased().contains { vowels.contains($0) }

        if word.count > 10 && isMixedCase && !hasVowel { return true }

        return false
    }
}
