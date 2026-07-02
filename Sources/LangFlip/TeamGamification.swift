import Foundation

// Pure logic behind the Team dashboard: who may see it, how activity converts
// to XP/levels, which badges unlock, and how players are ranked. No UI, no IO —
// everything here is deterministic and unit-tested (TeamDashboardTests).

/// Gate for the corporate Team section. Only signed-in accounts on the
/// company domain see the sidebar entry or the dashboard itself.
enum TeamAccess {
    static let requiredDomain = "uni.tech"

    /// True for emails whose domain is exactly `uni.tech` (case-insensitive,
    /// surrounding whitespace ignored). Look-alike domains ("notuni.tech") and
    /// subdomains don't qualify.
    static func isEligible(email: String?) -> Bool {
        guard let email else { return false }
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = normalized.lastIndex(of: "@") else { return false }
        return normalized[normalized.index(after: at)...] == requiredDomain
    }
}

enum TeamGamification {
    // MARK: XP

    /// XP for a period: every word counts, each dictation adds a flat bonus
    /// (rewarding the habit, not only volume), and each streak day adds a
    /// loyalty bonus so daily regulars outrank one-off bursts on quiet days.
    static let dictationBonus = 20
    static let streakDayBonus = 50

    static func xp(words: Int, dictations: Int, streakDays: Int) -> Int {
        max(0, words) + max(0, dictations) * dictationBonus + max(0, streakDays) * streakDayBonus
    }

    // MARK: Levels

    /// Quadratic curve: level n begins at `250 · n · (n − 1)` XP
    /// (L1 = 0, L2 = 500, L3 = 1 500, L4 = 3 000 …) — early levels come fast,
    /// later ones ask for real mileage.
    static func xpFloor(forLevel level: Int) -> Int {
        let n = max(1, level)
        return 250 * n * (n - 1)
    }

    static func level(forXP xp: Int) -> Int {
        guard xp > 0 else { return 1 }
        var level = 1
        while xpFloor(forLevel: level + 1) <= xp { level += 1 }
        return level
    }

    /// 0…1 progress from the current level's floor to the next one's.
    static func progressToNextLevel(forXP xp: Int) -> Double {
        let level = level(forXP: xp)
        let floor = xpFloor(forLevel: level)
        let ceiling = xpFloor(forLevel: level + 1)
        guard ceiling > floor else { return 0 }
        return min(1, max(0, Double(xp - floor) / Double(ceiling - floor)))
    }

    static let levelTitles = [
        "Newcomer", "Warm Mic", "Storyteller", "Wordsmith", "Pace Setter",
        "Flow Rider", "Deskside Orator", "Momentum Machine", "Team Voice",
        "Dictation Dynamo", "Office Legend", "Voice of uni.tech",
    ]

    static func title(forLevel level: Int) -> String {
        levelTitles[min(max(level, 1), levelTitles.count) - 1]
    }

    // MARK: Ranking

    struct RankedPlayer: Identifiable, Equatable {
        let rank: Int
        let player: BackendLeaderboardPlayer
        let xp: Int
        let isYou: Bool
        var id: String { player.id }
    }

    /// Sorts by XP (ties: more words, then name for stability), assigns 1-based
    /// ranks, and flags the caller's own row.
    static func ranked(_ players: [BackendLeaderboardPlayer], yourID: String?) -> [RankedPlayer] {
        let scored = players.map { player in
            (player: player, xp: xp(words: player.words, dictations: player.dictations, streakDays: player.streakDays))
        }
        let sorted = scored.sorted {
            if $0.xp != $1.xp { return $0.xp > $1.xp }
            if $0.player.words != $1.player.words { return $0.player.words > $1.player.words }
            return $0.player.name.localizedCaseInsensitiveCompare($1.player.name) == .orderedAscending
        }
        return sorted.enumerated().map { index, entry in
            RankedPlayer(rank: index + 1, player: entry.player, xp: entry.xp, isYou: entry.player.id == yourID)
        }
    }

    // MARK: Badges

    struct Badge: Identifiable, Equatable {
        let id: String
        let icon: String
        let title: String
        let detail: String
        let unlocked: Bool
    }

    /// Everything a badge can look at, distilled from local dictation history.
    struct BadgeInputs: Equatable {
        var totalWords = 0
        var totalDictations = 0
        var currentStreak = 0
        var longestStreak = 0
        var maxWordsInOneDictation = 0
        var hasDictationBefore8am = false
        var hasDictationAfter10pm = false
    }

    static func badges(_ input: BadgeInputs) -> [Badge] {
        [
            Badge(id: "first-words", icon: "waveform",
                  title: "First Words", detail: "Complete your first dictation.",
                  unlocked: input.totalDictations >= 1),
            Badge(id: "wordsmith", icon: "textformat",
                  title: "Wordsmith", detail: "Dictate 1,000 words in total.",
                  unlocked: input.totalWords >= 1_000),
            Badge(id: "novelist", icon: "book.closed",
                  title: "Novelist", detail: "Dictate 10,000 words in total.",
                  unlocked: input.totalWords >= 10_000),
            Badge(id: "living-keyboard", icon: "crown",
                  title: "Living Keyboard", detail: "Dictate 100,000 words in total.",
                  unlocked: input.totalWords >= 100_000),
            Badge(id: "warming-up", icon: "flame",
                  title: "Warming Up", detail: "Keep a 3-day streak.",
                  unlocked: input.longestStreak >= 3),
            Badge(id: "on-fire", icon: "flame.fill",
                  title: "On Fire", detail: "Keep a 7-day streak.",
                  unlocked: input.longestStreak >= 7),
            Badge(id: "unstoppable", icon: "bolt.fill",
                  title: "Unstoppable", detail: "Keep a 30-day streak.",
                  unlocked: input.longestStreak >= 30),
            Badge(id: "marathon", icon: "figure.run",
                  title: "Marathon Monologue", detail: "500+ words in a single dictation.",
                  unlocked: input.maxWordsInOneDictation >= 500),
            Badge(id: "early-bird", icon: "sunrise",
                  title: "Early Bird", detail: "Dictate before 8 a.m.",
                  unlocked: input.hasDictationBefore8am),
            Badge(id: "night-owl", icon: "moon.stars",
                  title: "Night Owl", detail: "Dictate after 10 p.m.",
                  unlocked: input.hasDictationAfter10pm),
        ]
    }

    /// Distills badge inputs from local history. `calendar`/`now` injectable
    /// for tests.
    static func badgeInputs(entries: [DictationEntry], calendar: Calendar = .current, now: Date = Date()) -> BadgeInputs {
        let completed = entries.filter(\.isTranscribed)
        var input = BadgeInputs()
        input.totalDictations = completed.count
        var days = Set<Date>()
        for entry in completed {
            let words = entry.wordCount
            input.totalWords += words
            input.maxWordsInOneDictation = max(input.maxWordsInOneDictation, words)
            let hour = calendar.component(.hour, from: entry.date)
            if hour < 8 { input.hasDictationBefore8am = true }
            if hour >= 22 { input.hasDictationAfter10pm = true }
            days.insert(calendar.startOfDay(for: entry.date))
        }
        let today = calendar.startOfDay(for: now)
        input.currentStreak = streak(days: days, endingAt: today, calendar: calendar)
        input.longestStreak = longestStreak(days: days, calendar: calendar)
        return input
    }

    static func streak(days: Set<Date>, endingAt day: Date, calendar: Calendar) -> Int {
        var count = 0
        var cursor = day
        while days.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    static func longestStreak(days: Set<Date>, calendar: Calendar) -> Int {
        let sorted = days.sorted()
        guard !sorted.isEmpty else { return 0 }
        var longest = 1
        var current = 1
        for i in 1..<sorted.count {
            if calendar.dateComponents([.day], from: sorted[i - 1], to: sorted[i]).day == 1 {
                current += 1
                longest = max(longest, current)
            } else {
                current = 1
            }
        }
        return longest
    }
}
