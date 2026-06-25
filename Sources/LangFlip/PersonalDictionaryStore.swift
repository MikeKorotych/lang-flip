import Foundation

struct PersonalDictionaryEntry: Identifiable, Codable, Equatable {
    enum Source: String, Codable {
        case manual
        case automatic
    }

    let id: UUID
    var canonical: String
    var variants: [String]
    var source: Source
    var createdAt: Date
    var updatedAt: Date
    var useCount: Int

    init(
        id: UUID = UUID(),
        canonical: String,
        variants: [String],
        source: Source,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        useCount: Int = 0
    ) {
        self.id = id
        self.canonical = canonical
        self.variants = variants
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.useCount = useCount
    }
}

final class PersonalDictionaryStore: ObservableObject {
    static let shared = PersonalDictionaryStore()

    @Published private(set) var entries: [PersonalDictionaryEntry] = []

    private let key = "lf.personalDictionary.entries"
    private let maxEntries = 250
    private let maxVariantsPerEntry = 12

    private init() { load() }

    func addManual(canonical: String, variant: String?) {
        add(canonical: canonical, variants: [variant].compactMap { $0 }, source: .manual)
    }

    func addAutomatic(canonical: String, variant: String) {
        add(canonical: canonical, variants: [variant], source: .automatic)
    }

    func remove(_ entry: PersonalDictionaryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clearAutomatic() {
        entries.removeAll { $0.source == .automatic }
        save()
    }

    func clearAll() {
        entries.removeAll()
        save()
    }

    func apply(to text: String) -> String {
        guard !entries.isEmpty, !text.isEmpty else { return text }
        var result = text
        let replacements = entries.flatMap { entry in
            entry.variants.map { variant in
                (variant: variant, canonical: entry.canonical)
            }
        }
        .filter { !$0.variant.isEmpty && $0.variant != $0.canonical }
        .sorted { lhs, rhs in lhs.variant.count > rhs.variant.count }

        for replacement in replacements {
            let pattern = "(?<![\\p{L}\\p{N}])"
                + NSRegularExpression.escapedPattern(for: replacement.variant)
                + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement.canonical)
            )
        }
        return result
    }

    private func add(canonical rawCanonical: String, variants rawVariants: [String], source: PersonalDictionaryEntry.Source) {
        let canonical = Self.cleanedTerm(rawCanonical)
        guard Self.isUsefulCanonical(canonical) else { return }

        var variants = rawVariants
            .map(Self.cleanedTerm)
            .filter { Self.isUsefulVariant($0, canonical: canonical) }
            .uniqueCaseInsensitive()
        let lowercaseCanonical = canonical.lowercased()
        if lowercaseCanonical != canonical, !variants.contains(where: { $0.lowercased() == lowercaseCanonical }) {
            variants.append(lowercaseCanonical)
        }

        let canonicalKey = canonical.lowercased()
        let now = Date()
        if let idx = entries.firstIndex(where: { $0.canonical.lowercased() == canonicalKey }) {
            var entry = entries[idx]
            entry.canonical = canonical
            entry.source = entry.source == .manual ? .manual : source
            entry.updatedAt = now
            let mergedVariants = (entry.variants + variants).uniqueCaseInsensitive()
            entry.variants = Array(mergedVariants.prefix(maxVariantsPerEntry))
            entries[idx] = entry
        } else {
            var next = PersonalDictionaryEntry(
                canonical: canonical,
                variants: variants,
                source: source,
                createdAt: now,
                updatedAt: now
            )
            if next.variants.isEmpty {
                next.variants = variants
            }
            entries.insert(next, at: 0)
            if entries.count > maxEntries {
                entries.removeLast(entries.count - maxEntries)
            }
        }
        save()
    }

    private static func cleanedTerm(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func isUsefulCanonical(_ value: String) -> Bool {
        guard value.count >= 2, value.count <= 80 else { return false }
        guard value.rangeOfCharacter(from: .letters) != nil else { return false }
        guard !value.contains("\n") && !value.contains("\r") else { return false }
        return true
    }

    private static func isUsefulVariant(_ value: String, canonical: String) -> Bool {
        guard value.count >= 2, value.count <= 80 else { return false }
        guard value.rangeOfCharacter(from: .letters) != nil else { return false }
        guard !value.contains("\n") && !value.contains("\r") else { return false }
        return value != canonical
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([PersonalDictionaryEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

private extension Array where Element == String {
    func uniqueCaseInsensitive() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in self {
            let key = item.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(item)
        }
        return result
    }
}
