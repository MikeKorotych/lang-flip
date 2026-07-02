import Foundation

// Pure logic behind the Team dashboard: who may see it, how words are ranked,
// which badges unlock, and the legacy XP helpers kept for compatibility. No UI,
// no IO — everything here is deterministic and unit-tested (TeamDashboardTests).

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
        let activityWords: Int
        let xp: Int
        let isYou: Bool
        var id: String { player.id }
    }

    /// Sorts by raw dictated words — the activity users already understand from
    /// the weekly quota. Dictations and streaks only break ties, then name keeps
    /// the order stable.
    static func ranked(_ players: [BackendLeaderboardPlayer], yourID: String?) -> [RankedPlayer] {
        let scored = players.map { player in
            (player: player,
             words: max(0, player.words),
             xp: xp(words: player.words, dictations: player.dictations, streakDays: player.streakDays))
        }
        let sorted = scored.sorted {
            if $0.words != $1.words { return $0.words > $1.words }
            if $0.player.dictations != $1.player.dictations { return $0.player.dictations > $1.player.dictations }
            if $0.player.streakDays != $1.player.streakDays { return $0.player.streakDays > $1.player.streakDays }
            return $0.player.name.localizedCaseInsensitiveCompare($1.player.name) == .orderedAscending
        }
        return sorted.enumerated().map { index, entry in
            RankedPlayer(rank: index + 1, player: entry.player, activityWords: entry.words,
                         xp: entry.xp, isYou: entry.player.id == yourID)
        }
    }

    // MARK: Board insights (team pulse / your standing / movers)

    /// Team-wide totals for one board, with an optional trend against the
    /// closed previous period.
    struct TeamPulse: Equatable {
        let totalWords: Int
        let activeMembers: Int       // players with any words this period
        let averageWords: Int        // per active member
        let previousTotalWords: Int?

        /// Whole-percent change vs the previous period; nil when there is no
        /// (or an empty) previous board to compare against.
        var trendPercent: Int? {
            guard let previous = previousTotalWords, previous > 0 else { return nil }
            return Int((Double(totalWords - previous) / Double(previous) * 100).rounded())
        }
    }

    /// Where you sit on a board, phrased for motivation: rank, movement since
    /// the previous period, and the concrete word gaps worth closing.
    struct YourStanding: Equatable {
        let rank: Int
        let totalPlayers: Int
        let words: Int
        /// Positive = climbed that many places since the previous period;
        /// nil when you were not on the previous board.
        let rankDelta: Int?
        /// Words behind the player directly above you; nil when you lead.
        let gapToNext: Int?
        /// Words behind #5 — only set when you are outside the top five.
        let gapToTopFive: Int?
        /// Your lead over #2 when you are the leader (and not alone).
        let leadOverNext: Int?
    }

    /// Someone who moved — either up the ranks or by sheer word growth.
    struct Mover: Equatable {
        let player: BackendLeaderboardPlayer
        let rankClimb: Int
        let wordsGained: Int
    }

    /// Everything the dashboard shows about one board beyond the raw rows.
    /// `previous` is the closed previous period (unranked, as the server sent
    /// it); pass nil when unavailable and the comparative fields stay empty.
    struct BoardInsights: Equatable {
        let pulse: TeamPulse
        let you: YourStanding?
        let topClimber: Mover?
        let mostImproved: Mover?
        /// id → rank movement (+ up, − down) for row chips. Absent id = new
        /// entrant this period.
        let rankDeltas: [String: Int]

        static let empty = BoardInsights(
            pulse: TeamPulse(totalWords: 0, activeMembers: 0, averageWords: 0, previousTotalWords: nil),
            you: nil, topClimber: nil, mostImproved: nil, rankDeltas: [:])
    }

    static func insights(current: [RankedPlayer], previous: [BackendLeaderboardPlayer]?) -> BoardInsights {
        let previousRanked = previous.map { ranked($0, yourID: nil) }
        let previousRankByID = Dictionary(uniqueKeysWithValues: (previousRanked ?? []).map { ($0.id, $0.rank) })
        let previousWordsByID = Dictionary(uniqueKeysWithValues: (previousRanked ?? []).map { ($0.id, $0.activityWords) })

        let totalWords = current.reduce(0) { $0 + $1.activityWords }
        let active = current.filter { $0.activityWords > 0 }.count
        let pulse = TeamPulse(
            totalWords: totalWords,
            activeMembers: active,
            averageWords: active > 0 ? Int((Double(totalWords) / Double(active)).rounded()) : 0,
            previousTotalWords: previousRanked.map { boards in boards.reduce(0) { $0 + $1.activityWords } })

        var deltas: [String: Int] = [:]
        for row in current {
            if let was = previousRankByID[row.id] { deltas[row.id] = was - row.rank }
        }

        var you: YourStanding?
        if let yourRow = current.first(where: \.isYou) {
            let above = current.first { $0.rank == yourRow.rank - 1 }
            let fifth = current.first { $0.rank == 5 }
            let second = current.first { $0.rank == 2 }
            you = YourStanding(
                rank: yourRow.rank,
                totalPlayers: current.count,
                words: yourRow.activityWords,
                rankDelta: deltas[yourRow.id],
                gapToNext: above.map { max(0, $0.activityWords - yourRow.activityWords) },
                gapToTopFive: yourRow.rank > 5
                    ? fifth.map { max(0, $0.activityWords - yourRow.activityWords) }
                    : nil,
                leadOverNext: yourRow.rank == 1
                    ? second.map { max(0, yourRow.activityWords - $0.activityWords) }
                    : nil)
        }

        // Biggest climb: best positive rank movement among returning players;
        // ties go to whoever gained more words.
        let climber = current
            .compactMap { row -> Mover? in
                guard let delta = deltas[row.id], delta > 0 else { return nil }
                return Mover(player: row.player, rankClimb: delta,
                             wordsGained: row.activityWords - (previousWordsByID[row.id] ?? 0))
            }
            .max { a, b in
                if a.rankClimb != b.rankClimb { return a.rankClimb < b.rankClimb }
                return a.wordsGained < b.wordsGained
            }

        // Most improved: largest word growth vs the previous period (new
        // entrants count from zero). Only meaningful with a previous board.
        let improved = previousRanked == nil ? nil : current
            .map { row in
                Mover(player: row.player, rankClimb: deltas[row.id] ?? 0,
                      wordsGained: row.activityWords - (previousWordsByID[row.id] ?? 0))
            }
            .filter { $0.wordsGained > 0 }
            .max { $0.wordsGained < $1.wordsGained }

        return BoardInsights(pulse: pulse, you: you, topClimber: climber,
                             mostImproved: improved, rankDeltas: deltas)
    }

    // MARK: Activity summaries

    struct ActivitySummary: Equatable {
        var words = 0
        var dictations = 0
        var activeDays = 0
        var bestDayWords = 0

        var averageWordsPerActiveDay: Int {
            guard activeDays > 0 else { return 0 }
            return Int((Double(words) / Double(activeDays)).rounded())
        }
    }

    static func activitySummary(entries: [DictationEntry], interval: DateInterval,
                                calendar: Calendar = .current) -> ActivitySummary {
        var summary = ActivitySummary()
        var wordsByDay: [Date: Int] = [:]
        for entry in entries where entry.isTranscribed && interval.contains(entry.date) {
            let words = entry.wordCount
            summary.words += words
            summary.dictations += 1
            wordsByDay[calendar.startOfDay(for: entry.date), default: 0] += words
        }
        summary.activeDays = wordsByDay.count
        summary.bestDayWords = wordsByDay.values.max() ?? 0
        return summary
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
            Badge(id: "chapter-builder", icon: "doc.text",
                  title: "Chapter Builder", detail: "Dictate 25,000 words in total.",
                  unlocked: input.totalWords >= 25_000),
            Badge(id: "living-keyboard", icon: "crown",
                  title: "Living Keyboard", detail: "Dictate 100,000 words in total.",
                  unlocked: input.totalWords >= 100_000),
            Badge(id: "voice-archive", icon: "archivebox",
                  title: "Voice Archive", detail: "Dictate 250,000 words in total.",
                  unlocked: input.totalWords >= 250_000),
            Badge(id: "voice-vault", icon: "archivebox.fill",
                  title: "Voice Vault", detail: "Dictate 500,000 words in total.",
                  unlocked: input.totalWords >= 500_000),
            Badge(id: "warming-up", icon: "flame",
                  title: "Warming Up", detail: "Keep a 3-day streak.",
                  unlocked: input.longestStreak >= 3),
            Badge(id: "on-fire", icon: "flame.fill",
                  title: "On Fire", detail: "Keep a 7-day streak.",
                  unlocked: input.longestStreak >= 7),
            Badge(id: "two-week-flow", icon: "calendar",
                  title: "Two-Week Flow", detail: "Keep a 14-day streak.",
                  unlocked: input.longestStreak >= 14),
            Badge(id: "relay-runner", icon: "calendar.circle",
                  title: "Relay Runner", detail: "Keep a 21-day streak.",
                  unlocked: input.longestStreak >= 21),
            Badge(id: "unstoppable", icon: "bolt.fill",
                  title: "Unstoppable", detail: "Keep a 30-day streak.",
                  unlocked: input.longestStreak >= 30),
            Badge(id: "iron-streak", icon: "shield.fill",
                  title: "Iron Streak", detail: "Keep a 60-day streak.",
                  unlocked: input.longestStreak >= 60),
            Badge(id: "habit-builder", icon: "mic",
                  title: "Habit Builder", detail: "Complete 10 dictations.",
                  unlocked: input.totalDictations >= 10),
            Badge(id: "meeting-scribe", icon: "mic.fill",
                  title: "Meeting Scribe", detail: "Complete 50 dictations.",
                  unlocked: input.totalDictations >= 50),
            Badge(id: "century-mic", icon: "record.circle",
                  title: "Century Mic", detail: "Complete 100 dictations.",
                  unlocked: input.totalDictations >= 100),
            Badge(id: "daily-driver", icon: "mic.circle",
                  title: "Daily Driver", detail: "Complete 250 dictations.",
                  unlocked: input.totalDictations >= 250),
            Badge(id: "marathon", icon: "figure.run",
                  title: "Marathon Monologue", detail: "500+ words in a single dictation.",
                  unlocked: input.maxWordsInOneDictation >= 500),
            Badge(id: "deep-session", icon: "timer",
                  title: "Deep Session", detail: "1,500+ words in a single dictation.",
                  unlocked: input.maxWordsInOneDictation >= 1_500),
            Badge(id: "longform-mode", icon: "speedometer",
                  title: "Longform Mode", detail: "3,000+ words in a single dictation.",
                  unlocked: input.maxWordsInOneDictation >= 3_000),
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
