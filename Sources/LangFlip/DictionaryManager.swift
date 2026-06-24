import Foundation

enum DictionaryManager {
    struct LanguageStats: Equatable {
        let bundledCount: Int
        let installedCount: Int
        let effectiveCount: Int
    }

    static let extendedPackSource = "hermitdave/FrequencyWords, OpenSubtitles 2018"
    static let extendedPackLicense = "CC BY-SA 4.0"

    private static let maxInstalledWordsPerLanguage = 120_000
    private static let crossLanguageContaminationRatio = 50

    private static let urls: [Layout: URL] = [
        .en: URL(string: "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/en/en_full.txt")!,
        .uk: URL(string: "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/uk/uk_full.txt")!,
        .ru: URL(string: "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/ru/ru_full.txt")!,
    ]

    static var dictionariesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("LangFlip/Dictionaries", isDirectory: true)
    }

    static func installedURL(for layout: Layout) -> URL {
        dictionariesDirectory.appendingPathComponent("\(layout.rawValue)-words.txt")
    }

    static func installedWords(for layout: Layout) -> Set<String> {
        guard let raw = try? String(contentsOf: installedURL(for: layout), encoding: .utf8) else {
            return []
        }
        return Set(raw.split(whereSeparator: { $0.isNewline }).map(String.init))
    }

    static func stats() -> [Layout: LanguageStats] {
        var result: [Layout: LanguageStats] = [:]
        for layout in Layout.allCases {
            let bundled = bundledWords(for: layout)
            let installed = installedWords(for: layout)
            result[layout] = LanguageStats(
                bundledCount: bundled.count,
                installedCount: installed.count,
                effectiveCount: bundled.union(installed).count
            )
        }
        return result
    }

    static func installExtendedFrequencyPack(
        progress: ((Int, Int) -> Void)? = nil,
        completion: @escaping (Result<[Layout: Int], Error>) -> Void
    ) {
        AppLog.write("dictionary install started")
        let group = DispatchGroup()
        let lock = NSLock()
        var rawTexts: [Layout: String] = [:]
        var firstError: Error?

        for (layout, url) in urls {
            group.enter()
            URLSession.shared.dataTask(with: url) { data, _, error in
                defer { group.leave() }
                if let error {
                    AppLog.write("dictionary download failed layout=\(layout.rawValue): \(error.localizedDescription)")
                    lock.lock()
                    if firstError == nil { firstError = error }
                    lock.unlock()
                    return
                }
                guard let data, let text = String(data: data, encoding: .utf8) else {
                    AppLog.write("dictionary download invalid layout=\(layout.rawValue)")
                    lock.lock()
                    if firstError == nil { firstError = CocoaError(.fileReadCorruptFile) }
                    lock.unlock()
                    return
                }
                AppLog.write("dictionary download finished layout=\(layout.rawValue) bytes=\(data.count)")
                lock.lock()
                rawTexts[layout] = text
                let completed = rawTexts.count
                lock.unlock()
                if let progress {
                    DispatchQueue.main.async {
                        progress(completed, urls.count)
                    }
                }
            }.resume()
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            if let firstError {
                completion(.failure(firstError))
                return
            }
            guard rawTexts.keys.count == urls.keys.count else {
                completion(.failure(CocoaError(.fileReadUnknown)))
                return
            }

            do {
                AppLog.write("dictionary cleaning started")
                let parsed = rawTexts.mapValues(parseFrequencyList)
                let cleaned = buildCleanWordLists(from: parsed)
                try FileManager.default.createDirectory(at: dictionariesDirectory, withIntermediateDirectories: true)

                var counts: [Layout: Int] = [:]
                for layout in Layout.allCases {
                    let words = cleaned[layout] ?? []
                    let body = words.joined(separator: "\n") + "\n"
                    try body.write(to: installedURL(for: layout), atomically: true, encoding: .utf8)
                    counts[layout] = words.count
                    AppLog.write("dictionary wrote layout=\(layout.rawValue) words=\(words.count)")
                }
                NotificationCenter.default.post(name: .langFlipDictionariesChanged, object: nil)
                AppLog.write("dictionary install completed")
                completion(.success(counts))
            } catch {
                AppLog.write("dictionary install failed: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }

    /// Installs the extended packs once, silently in the background, on first
    /// launch — so they're present by default without the user clicking
    /// anything. Skips if already installed, or if a prior auto-install already
    /// succeeded (so a deliberate Reset isn't undone). Retries next launch if a
    /// download fails (e.g. offline).
    static func autoInstallExtendedPacksIfNeeded() {
        let key = "lf.didAutoInstallDicts"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        if stats().values.contains(where: { $0.installedCount > 0 }) {
            UserDefaults.standard.set(true, forKey: key)
            return
        }
        AppLog.write("auto-installing extended dictionaries on first launch")
        installExtendedFrequencyPack { result in
            switch result {
            case .success:
                UserDefaults.standard.set(true, forKey: key)
                AppLog.write("auto-install dictionaries: success")
            case .failure(let error):
                AppLog.write("auto-install dictionaries failed (retry next launch): \(error.localizedDescription)")
            }
        }
    }

    static func resetInstalledDictionaries() throws {
        for layout in Layout.allCases {
            let url = installedURL(for: layout)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        NotificationCenter.default.post(name: .langFlipDictionariesChanged, object: nil)
    }

    private static func bundledWords(for layout: Layout) -> Set<String> {
        switch layout {
        case .en:
            guard let raw = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else {
                return []
            }
            return Set(raw.split(whereSeparator: { $0.isNewline }).map { $0.lowercased() })
        case .uk, .ru:
            return bundledWordList(for: layout)
        }
    }

    private static func bundledWordList(for layout: Layout) -> Set<String> {
        let name = "\(layout.rawValue)-words"
        if let url = Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Dictionaries"),
           let raw = try? String(contentsOf: url, encoding: .utf8) {
            return Set(raw.split(whereSeparator: { $0.isNewline }).map(String.init))
        }
        if let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Dictionaries"),
           let raw = try? String(contentsOf: url, encoding: .utf8) {
            return Set(raw.split(whereSeparator: { $0.isNewline }).map(String.init))
        }
        return []
    }

    private static func parseFrequencyList(_ raw: String) -> [(word: String, frequency: Int)] {
        raw.split(whereSeparator: { $0.isNewline }).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard let wordPart = parts.first else { return nil }
            let word = String(wordPart).lowercased()
            let frequency = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 1 : 1
            return (word, frequency)
        }
    }

    private static func buildCleanWordLists(from parsed: [Layout: [(word: String, frequency: Int)]]) -> [Layout: [String]] {
        let freqMaps = parsed.mapValues(frequencyMap)

        var result: [Layout: [String]] = [:]
        for layout in Layout.allCases {
            var words: [String] = []
            var seen = Set<String>()
            let entries = parsed[layout] ?? []
            let otherLayout: Layout? = layout == .uk ? .ru : (layout == .ru ? .uk : nil)
            let otherFreqs = otherLayout.flatMap { freqMaps[$0] } ?? [:]

            for entry in entries {
                let word = entry.word
                guard word.count >= 3, isAllowed(word, for: layout), !seen.contains(word) else { continue }

                if let other = otherLayout, other == .uk || other == .ru {
                    let otherFrequency = otherFreqs[word] ?? 0
                    if entry.frequency > 0,
                       otherFrequency >= entry.frequency * crossLanguageContaminationRatio {
                        continue
                    }
                }

                seen.insert(word)
                words.append(word)
                if words.count >= maxInstalledWordsPerLanguage { break }
            }
            result[layout] = words
        }
        return result
    }

    private static func frequencyMap(from entries: [(word: String, frequency: Int)]) -> [String: Int] {
        var result: [String: Int] = [:]
        for entry in entries {
            result[entry.word] = max(result[entry.word] ?? 0, entry.frequency)
        }
        return result
    }

    private static func isAllowed(_ word: String, for layout: Layout) -> Bool {
        let allowed: Set<Character>
        switch layout {
        case .en:
            allowed = Set("abcdefghijklmnopqrstuvwxyz")
        case .uk:
            allowed = Set("абвгґдеєжзиіїйклмнопрстуфхцчшщьюя")
        case .ru:
            allowed = Set("абвгдеёжзийклмнопрстуфхцчшщъыьэюя")
        }
        return word.allSatisfy { allowed.contains($0) }
    }
}
