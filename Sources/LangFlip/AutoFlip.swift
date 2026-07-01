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

    /// All three sets are guarded by `lock`. Readers take a copy of
    /// the three Set references under the lock, then perform the
    /// `.contains` lookup outside it — Swift Sets are COW so the copy
    /// is just a ref bump, and a concurrent writer replacing the
    /// property doesn't affect a reader that already grabbed a ref to
    /// the old storage.
    private var enWords: Set<String> = []
    private var ukCommon: Set<String> = []
    private var ruCommon: Set<String> = []
    private static let ukFalsePositiveWords: Set<String> = [
        "біл",
    ]
    /// False until the background `reloadDictionaries` finishes. The
    /// EmbeddedDicts seed is too small (only a few hundred high-freq
    /// UK/RU words, no English) to power dictionary-based scoring —
    /// we'd score "hello" at 1 (looksLikeEnglish heuristic) instead of
    /// 2 (in dict), losing the score gap that triggers auto-flip. Hold
    /// off entirely until the real dicts are in.
    private var dictsReady = false
    private let lock = NSLock()

    private init() {
        // Seed UK / RU synchronously from the tiny embedded fallback
        // so cross-layout heuristics have *something* to query while
        // the heavy load runs in the background. Auto-flip stays
        // gated behind `dictsReady` regardless — see the early-return
        // at the top of suggestedFlip.
        ukCommon = Set(EmbeddedDicts.ukrainian.map { $0.lowercased() })
        ruCommon = Set(EmbeddedDicts.russian.map { $0.lowercased() })

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.reloadDictionaries()
        }
        _ = NotificationCenter.default.addObserver(
            forName: .langFlipDictionariesChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.global(qos: .userInitiated).async {
                self?.reloadDictionaries()
            }
        }
    }

    /// True once the background dictionary load has populated the
    /// real EN/UK/RU sets. Callers that NEED dictionary coverage
    /// (auto-flip scoring) check this and skip otherwise.
    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return dictsReady
    }

    func reloadDictionaries() {
        // System English dictionary (preinstalled on macOS in /usr/share/dict/words).
        // If absent (chrooted env, customized macOS, etc.), auto-flip can still
        // work but loses its strongest "is this a real English word?" signal.
        let dictPath = "/usr/share/dict/words"
        var newEn: Set<String> = []
        if let raw = try? String(contentsOfFile: dictPath, encoding: .utf8) {
            newEn = Set(raw.split(separator: "\n").map { $0.lowercased() })
        } else {
            FileHandle.standardError.write(Data(
                "lang-flip: could not read \(dictPath); auto-flip will rely on heuristics for English.\n".utf8
            ))
        }
        newEn.formUnion(DictionaryManager.installedWords(for: .en))

        // UK / RU lists shipped as bundled resources (built by
        // Scripts/build-dicts.sh). If a file is missing — e.g. running from
        // outside the .app or from a fresh checkout where the script hasn't
        // been run — fall back to the much smaller embedded list so the
        // negative signal still works for the most common words.
        var newUk = Self.loadResource(name: "uk-words", fallback: EmbeddedDicts.ukrainian)
        var newRu = Self.loadResource(name: "ru-words", fallback: EmbeddedDicts.russian)
        newUk.formUnion(DictionaryManager.installedWords(for: .uk))
        newRu.formUnion(DictionaryManager.installedWords(for: .ru))
        newUk.subtract(Self.ukFalsePositiveWords)

        // Atomically swap. Readers will see either old or new sets,
        // never a partially-populated state.
        lock.lock()
        enWords = newEn
        ukCommon = newUk
        ruCommon = newRu
        dictsReady = true
        lock.unlock()

        // Refresh any UI that was showing word counts (Preferences >
        // Languages dictionary status).
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .langFlipDictionariesReloaded, object: nil)
        }
    }

    /// Ensure dictionary-scored paths are ready before typing starts. EventTap
    /// calls this during startup so the first completed word does not silently
    /// miss auto-flip while the background load is still warming up.
    func ensureReadyForTyping() {
        if isReady { return }
        reloadDictionaries()
    }

    /// Snapshot the three sets under the lock and return references.
    /// COW means the cost is just a ref-count bump per Set. Callers
    /// perform `.contains` on the local copies — no further locking
    /// needed, even if a concurrent reload swaps in new sets.
    private func dictSnapshot() -> (Set<String>, Set<String>, Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        return (enWords, ukCommon, ruCommon)
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
        // Compute the lowercased form once. Earlier code rebuilt it
        // inside isForcedKeep, forcedFlip, looksLikePassword, and the
        // body below — that's a 4× Unicode walk per word boundary on
        // the hot path. Helpers below now take `lower` as a parameter.
        let lower = word.lowercased()

        // Words the user previously rejected via Backspace — never auto-flip.
        if BackspaceLearner.shared.isExcluded(word) { return nil }
        // Hand-picked false positives that are common real words in the
        // source layout, even when the converted form also looks valid.
        if isForcedKeep(lower: lower, currentLayout: currentLayout) { return nil }
        // User-managed and built-in forced rules are deterministic and do
        // not depend on dictionary coverage, so they can run even while the
        // heavy background dictionary load is still warming up.
        // Pass the original-case word: always-flip rules are case-sensitive, so a
        // rule for "срфеПЗЕ" (ChatGPT) matches the capitalised token, not "срфепзе".
        if let target = AlwaysFlipRules.shared.target(for: word, currentLayout: currentLayout) {
            return target
        }
        // Hand-picked short phrases where dictionary scoring is too
        // conservative but the intent is clear in day-to-day typing.
        if let forced = forcedFlip(lower: lower, currentLayout: currentLayout) {
            return forced
        }
        // Refuse dictionary-scored auto-flips before the background load has
        // finished. The EmbeddedDicts seed is too small to drive scoring —
        // words like "hello"/"world" would score 1 (heuristic-only) instead
        // of 2 (in dict), defeating the score-gap requirement and producing
        // the "auto-flip sometimes silently doesn't work right after launch"
        // bug.
        guard isReady else { return nil }
        // Skip very short tokens — high false-positive rate ("я", "is", "и").
        guard word.count >= 3 else { return nil }
        // Skip anything with digits or non-letter cruft.
        if word.contains(where: { $0.isNumber }) { return nil }
        // High-entropy strings (passwords, tokens, hashes) — keep them as-is
        // even if a layout flip would produce dictionary chars.
        if looksLikePassword(word, lower: lower) { return nil }

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

    private func forcedFlip(lower: String, currentLayout: Layout) -> Layout? {
        switch (currentLayout, lower) {
        case (.uk, "бі"), (.uk, "ті"), (.uk, "єто"):
            return .ru
        default:
            return nil
        }
    }

    private func isForcedKeep(lower: String, currentLayout: Layout) -> Bool {
        switch (currentLayout, lower) {
        case (.uk, "тексті"), (.uk, "еще"),
             (.ru, "доступы"):
            return true
        default:
            return false
        }
    }

    /// True if `lowercased` is in any of our dictionaries. Used by
    /// DoubleCapsFix to confirm a sticky-shift correction would land on a
    /// real word rather than mangling an intentional acronym like "OAuth".
    func isKnownWord(_ lowercased: String) -> Bool {
        let (en, uk, ru) = dictSnapshot()
        return en.contains(lowercased)
            || uk.contains(lowercased)
            || ru.contains(lowercased)
    }

    /// Per-language lookups, used by CrossLayoutFix to disambiguate
    /// words like "новій" that are real Ukrainian *and* whose RU
    /// substitution ("новый") is real Russian. The bare isKnownWord
    /// can't tell them apart.
    func isKnownInUk(_ lowercased: String) -> Bool {
        lock.lock()
        let set = ukCommon
        lock.unlock()
        return set.contains(lowercased)
    }

    func isKnownInRu(_ lowercased: String) -> Bool {
        lock.lock()
        let set = ruCommon
        lock.unlock()
        return set.contains(lowercased)
    }

    func isKnown(_ lowercased: String, in layout: Layout) -> Bool {
        let (en, uk, ru) = dictSnapshot()
        switch layout {
        case .en: return en.contains(lowercased)
        case .uk: return uk.contains(lowercased)
        case .ru: return ru.contains(lowercased)
        }
    }

    /// 2 = in dictionary, 1 = plausibly word-shaped, 0 = noise.
    private func score(_ word: String, in layout: Layout) -> Int {
        let (en, uk, ru) = dictSnapshot()
        switch layout {
        case .en:
            return en.contains(word) ? 2 : (looksLikeEnglish(word) ? 1 : 0)
        case .uk:
            return uk.contains(word) ? 2 : (looksLikeCyrillic(word, allowed: ukAlphabet) ? 1 : 0)
        case .ru:
            return ru.contains(word) ? 2 : (looksLikeCyrillic(word, allowed: ruAlphabet) ? 1 : 0)
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
    private func looksLikePassword(_ word: String, lower: String) -> Bool {
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
        let hasVowel = lower.contains { vowels.contains($0) }

        if word.count > 10 && isMixedCase && !hasVowel { return true }

        return false
    }
}
