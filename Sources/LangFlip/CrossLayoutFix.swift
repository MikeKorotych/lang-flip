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
    ///
    /// `recentContext` is the buffer's recent-words history (most recent
    /// last). Used to disambiguate words that are real in *both*
    /// languages — see the cases at the bottom of this method.
    static func correction(
        for word: String,
        recentContext: [String] = [],
        autoFlip: AutoFlip = .shared
    ) -> Correction? {
        guard !word.isEmpty else { return nil }
        guard word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }) else { return nil }

        // Standalone-letter shortcut: a single "ы" or "э" between word
        // boundaries is almost certainly a typo for "і" or "є" — neither
        // ы nor э is a Russian word on its own, and the wrong-key pattern
        // is overwhelming. We skip the dict check here because our
        // bundled UK dictionary filters out 1-letter tokens during build,
        // so isKnownWord("і") would falsely return false.
        //
        // The reverse — standalone "і" / "є" — is intentionally NOT
        // shortcut-corrected, because both are real Ukrainian function
        // words ("і" = and, "є" = is). Touching them would produce
        // false positives.
        if word.count == 1, let only = word.first {
            let lowerOnly = Character(String(only).lowercased())
            if let pair = pairs.first(where: { $0.ru == lowerOnly }) {
                let mapped = only.isUppercase
                    ? Character(String(pair.uk).uppercased())
                    : pair.uk
                return Correction(corrected: String(mapped), target: .uk)
            }
            return nil
        }

        let lower = word.lowercased()
        let chars = Array(lower)

        // Decide direction by which side's exclusive letters appear. If
        // both sides' exclusive letters are present, the word is
        // genuinely mixed and we don't touch it.
        let hasRuExclusive = chars.contains { ruOnlyLetters.contains($0) }
        let hasUkExclusive = chars.contains { ukOnlyLetters.contains($0) }
        guard hasRuExclusive != hasUkExclusive else { return nil }

        // For each direction we ask three questions:
        //   1. Is the candidate substitution a real word in the OTHER
        //      language? If no → skip (substitution would be gibberish).
        //   2. Is the original a real word in its OWN language? If no →
        //      flip (typo for the other language's word).
        //   3. Both are real → AMBIGUOUS. Inspect the recent buffer for
        //      a clear language signal:
        //         - context unmistakably Russian → flip toward Russian
        //         - context unmistakably Ukrainian → flip toward Ukrainian
        //         - context mixed / unknown → keep as-is (conservative)
        //
        // This is the path that lets "новій" become "новый" inside an
        // otherwise-Russian sentence ("Это новій iPhone") while leaving
        // it alone inside an otherwise-Ukrainian sentence ("у новій
        // книзі").
        if hasRuExclusive {
            guard let candidate = substitute(word, mode: .ruToUk) else { return nil }
            guard candidate.lowercased().allSatisfy({ ukAlphabet.contains($0) }) else { return nil }
            guard candidate != word else { return nil }
            let candidateLower = candidate.lowercased()
            guard autoFlip.isKnownInUk(candidateLower) else { return nil }

            let originalIsRussian = autoFlip.isKnownInRu(lower)
            if !originalIsRussian {
                return Correction(corrected: candidate, target: .uk)
            }
            // Ambiguous: original is real RU, candidate is real UK.
            switch contextBias(recentContext: recentContext, autoFlip: autoFlip) {
            case .ukrainian: return Correction(corrected: candidate, target: .uk)
            case .russian, .neutral: return nil
            }
        } else {
            guard let candidate = substitute(word, mode: .ukToRu) else { return nil }
            guard candidate.lowercased().allSatisfy({ ruAlphabet.contains($0) }) else { return nil }
            guard candidate != word else { return nil }
            let candidateLower = candidate.lowercased()
            guard autoFlip.isKnownInRu(candidateLower) else { return nil }

            let originalIsUkrainian = autoFlip.isKnownInUk(lower)
            if !originalIsUkrainian {
                return Correction(corrected: candidate, target: .ru)
            }
            // Ambiguous: original is real UK, candidate is real RU.
            switch contextBias(recentContext: recentContext, autoFlip: autoFlip) {
            case .russian: return Correction(corrected: candidate, target: .ru)
            case .ukrainian, .neutral: return nil
            }
        }
    }

    private enum ContextBias { case russian, ukrainian, neutral }

    /// Inspect the recent buffer history for a single-language bias.
    /// Counts words that are exclusively in the UK or RU dictionary
    /// (not shared cognates, not unknown) — this gives a strong
    /// "the user is writing language X" signal even for words that
    /// don't have any layout-exclusive letters.
    ///
    /// Two layers:
    ///   1. Dict-based: count words that are exclusively in one
    ///      language's bundled dictionary.
    ///   2. Letter-based fallback: count language-exclusive letters
    ///      (ы / э / ё / ъ for RU, і / є / ї / ґ for UK) across the
    ///      context. The OpenSubtitles UK dict is contaminated with
    ///      Russian forms, so a dict-only check often misses obvious
    ///      Russian context like "Я хотел купить …". Letter signal
    ///      catches it whenever ANY word has an unambiguous letter.
    ///
    /// Either signal is enough to bias — but only when it's
    /// uncontested by a same-strength signal in the other direction.
    /// "Uncontested" is what keeps genuinely-mixed paragraphs neutral.
    private static func contextBias(recentContext: [String], autoFlip: AutoFlip) -> ContextBias {
        var ruDictOnly = 0
        var ukDictOnly = 0
        var ruLetters = 0
        var ukLetters = 0
        for word in recentContext {
            let lower = word.lowercased()
            let inUk = autoFlip.isKnownInUk(lower)
            let inRu = autoFlip.isKnownInRu(lower)
            if inUk && !inRu { ukDictOnly += 1 }
            else if !inUk && inRu { ruDictOnly += 1 }
            for ch in lower {
                if ruOnlyLetters.contains(ch) { ruLetters += 1 }
                else if ukOnlyLetters.contains(ch) { ukLetters += 1 }
            }
        }
        // Strong signal: dictionary exclusivity.
        if ruDictOnly >= 1 && ukDictOnly == 0 { return .russian }
        if ukDictOnly >= 1 && ruDictOnly == 0 { return .ukrainian }
        // Fallback: language-exclusive letters in any neighbouring word.
        if ruLetters >= 1 && ukLetters == 0 { return .russian }
        if ukLetters >= 1 && ruLetters == 0 { return .ukrainian }
        return .neutral
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
