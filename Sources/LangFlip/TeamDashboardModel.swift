import Foundation

/// State for the Team dashboard. Tries the backend leaderboard first; when the
/// endpoint is unavailable (not deployed yet, offline, signed out mid-view) it
/// degrades to a "preview" board built from the local dictation history — your
/// own row only, never invented teammates. Monthly support is additive: older
/// servers can omit it and the client will show your local month until the
/// backend catches up. Badges are always computed locally: they describe *your*
/// habits and need no server.
@MainActor
final class TeamDashboardModel: ObservableObject {
    enum Source: Equatable {
        case live(generatedAt: Date, includesMonthly: Bool)
        case localPreview
    }

    enum Period: String, CaseIterable {
        case daily = "Today"
        case weekly = "Week"
        case monthly = "Month"

        var storageKey: String {
            switch self {
            case .daily: return "daily"
            case .weekly: return "weekly"
            case .monthly: return "monthly"
            }
        }
    }

    @Published private(set) var daily: [TeamGamification.RankedPlayer] = []
    @Published private(set) var weekly: [TeamGamification.RankedPlayer] = []
    @Published private(set) var monthly: [TeamGamification.RankedPlayer] = []
    /// Closed previous periods (unranked, as served) — feed rank deltas,
    /// the team trend and the movers row. nil = server didn't provide them.
    @Published private(set) var previousDaily: [BackendLeaderboardPlayer]?
    @Published private(set) var previousWeekly: [BackendLeaderboardPlayer]?
    @Published private(set) var previousMonthly: [BackendLeaderboardPlayer]?
    @Published private(set) var badges: [TeamGamification.Badge] = []
    @Published private(set) var source: Source = .localPreview
    @Published private(set) var isLoading = false

    private let client: HTTPBackendClient
    private let history: DictationHistory
    private let auth: SupabaseBackendAuth
    private let defaults: UserDefaults

    init(client: HTTPBackendClient = .shared,
         history: DictationHistory = .shared,
         auth: SupabaseBackendAuth? = nil,
         defaults: UserDefaults = .standard) {
        self.client = client
        self.history = history
        self.auth = auth ?? SupabaseBackendAuth.shared
        self.defaults = defaults
    }

    func rows(for period: Period) -> [TeamGamification.RankedPlayer] {
        switch period {
        case .daily: daily
        case .weekly: weekly
        case .monthly: monthly
        }
    }

    var youThisWeek: TeamGamification.RankedPlayer? { weekly.first(where: \.isYou) }

    func previousBoard(for period: Period) -> [BackendLeaderboardPlayer]? {
        switch period {
        case .daily: previousDaily
        case .weekly: previousWeekly
        case .monthly: previousMonthly
        }
    }

    /// Team pulse, your standing and movers for one board — derived on demand
    /// from the published rows so it is always in sync with what is displayed.
    func insights(for period: Period) -> TeamGamification.BoardInsights {
        TeamGamification.insights(current: rows(for: period), previous: previousBoard(for: period))
    }
    var isLocalPreview: Bool { source == .localPreview }
    var isMonthlyLocalFallback: Bool {
        if case .live(_, let includesMonthly) = source {
            return !includesMonthly
        }
        return false
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        let freshBadges = TeamGamification.badges(TeamGamification.badgeInputs(entries: history.entries))
        badges = freshBadges
        notifyNewAchievementsIfNeeded(freshBadges)

        let yourID = auth.currentUser?.id
        let includeDevPreviewTeammates = Settings.shared.devTeamPreviewTeammates
        let preview = Self.localPreviewPlayers(
            entries: history.entries,
            id: yourID ?? "local",
            name: Self.displayName(email: auth.currentUser?.email,
                                   firstName: Settings.shared.accountFirstName,
                                   lastName: Settings.shared.accountLastName))
        do {
            let response = try await client.leaderboard()
            daily = TeamGamification.ranked(
                Self.withDevPreviewTeammates(response.daily, period: .daily,
                                             fallbackYou: preview.daily,
                                             enabled: includeDevPreviewTeammates),
                yourID: yourID ?? preview.daily.id)
            weekly = TeamGamification.ranked(
                Self.withDevPreviewTeammates(response.weekly, period: .weekly,
                                             fallbackYou: preview.weekly,
                                             enabled: includeDevPreviewTeammates),
                yourID: yourID ?? preview.weekly.id)
            let monthlyRows = response.monthly
            monthly = TeamGamification.ranked(
                Self.withDevPreviewTeammates(monthlyRows ?? [preview.monthly], period: .monthly,
                                             fallbackYou: preview.monthly,
                                             enabled: includeDevPreviewTeammates),
                yourID: monthlyRows == nil ? preview.monthly.id : (yourID ?? preview.monthly.id))
            previousDaily = Self.withDevPreviewPreviousTeammates(response.previousDaily, period: .daily,
                                                                 fallbackYou: preview.previousDaily,
                                                                 enabled: includeDevPreviewTeammates)
            previousWeekly = Self.withDevPreviewPreviousTeammates(response.previousWeekly, period: .weekly,
                                                                  fallbackYou: preview.previousWeekly,
                                                                  enabled: includeDevPreviewTeammates)
            previousMonthly = Self.withDevPreviewPreviousTeammates(response.previousMonthly, period: .monthly,
                                                                   fallbackYou: preview.previousMonthly,
                                                                   enabled: includeDevPreviewTeammates)
            source = .live(generatedAt: response.generatedAt, includesMonthly: monthlyRows != nil)
            notifyRankImprovementsIfNeeded()
        } catch {
            daily = TeamGamification.ranked(
                Self.withDevPreviewTeammates([preview.daily], period: .daily,
                                             fallbackYou: preview.daily,
                                             enabled: includeDevPreviewTeammates),
                yourID: preview.daily.id)
            weekly = TeamGamification.ranked(
                Self.withDevPreviewTeammates([preview.weekly], period: .weekly,
                                             fallbackYou: preview.weekly,
                                             enabled: includeDevPreviewTeammates),
                yourID: preview.weekly.id)
            monthly = TeamGamification.ranked(
                Self.withDevPreviewTeammates([preview.monthly], period: .monthly,
                                             fallbackYou: preview.monthly,
                                             enabled: includeDevPreviewTeammates),
                yourID: preview.monthly.id)
            previousDaily = Self.withDevPreviewPreviousTeammates([preview.previousDaily], period: .daily,
                                                                 fallbackYou: preview.previousDaily,
                                                                 enabled: includeDevPreviewTeammates)
            previousWeekly = Self.withDevPreviewPreviousTeammates([preview.previousWeekly], period: .weekly,
                                                                  fallbackYou: preview.previousWeekly,
                                                                  enabled: includeDevPreviewTeammates)
            previousMonthly = Self.withDevPreviewPreviousTeammates([preview.previousMonthly], period: .monthly,
                                                                   fallbackYou: preview.previousMonthly,
                                                                   enabled: includeDevPreviewTeammates)
            source = .localPreview
            notifyRankImprovementsIfNeeded()
        }
    }

    private func notifyNewAchievementsIfNeeded(_ freshBadges: [TeamGamification.Badge]) {
        let baselineKey = "lf.team.achievementsBaselineReady"
        let seenKey = "lf.team.seenUnlockedAchievements"
        let unlocked = freshBadges.filter(\.unlocked)
        let unlockedIDs = Set(unlocked.map(\.id))
        let seen = Set(defaults.stringArray(forKey: seenKey) ?? [])

        guard defaults.bool(forKey: baselineKey) else {
            defaults.set(Array(unlockedIDs), forKey: seenKey)
            defaults.set(true, forKey: baselineKey)
            return
        }

        let newIDs = unlockedIDs.subtracting(seen)
        guard !newIDs.isEmpty else {
            defaults.set(Array(seen.union(unlockedIDs)), forKey: seenKey)
            return
        }

        for badge in unlocked where newIDs.contains(badge.id) {
            AppNotifications.shared.post(
                id: "achievement-\(badge.id)",
                kind: .info,
                title: "Achievement unlocked",
                body: "\(badge.title) — \(badge.detail)"
            )
            Notifications.show(
                title: "Achievement unlocked",
                body: "\(badge.title) — \(badge.detail)",
                identifier: "achievement-\(badge.id)"
            )
        }
        defaults.set(Array(seen.union(unlockedIDs)), forKey: seenKey)
    }

    private func notifyRankImprovementsIfNeeded() {
        for period in Period.allCases {
            guard let standing = insights(for: period).you else { continue }
            let baselineKey = "lf.team.rankBaselineReady.\(period.storageKey)"
            let rankKey = "lf.team.lastRank.\(period.storageKey)"
            let previousRank = defaults.integer(forKey: rankKey)

            guard defaults.bool(forKey: baselineKey) else {
                defaults.set(standing.rank, forKey: rankKey)
                defaults.set(true, forKey: baselineKey)
                continue
            }

            if previousRank > 0, standing.rank < previousRank {
                let title = "Leaderboard climb"
                let body = "You moved from #\(previousRank) to #\(standing.rank) on the \(period.rawValue.lowercased()) board."
                AppNotifications.shared.post(
                    id: "rank-\(period.storageKey)",
                    kind: .info,
                    title: title,
                    body: body
                )
                Notifications.show(title: title, body: body, identifier: "rank-\(period.storageKey)")
            }
            defaults.set(standing.rank, forKey: rankKey)
        }
    }

    /// "First Last" from the locally-stored profile, else the email local-part,
    /// else a generic label.
    nonisolated static func displayName(email: String?, firstName: String, lastName: String) -> String {
        let full = [firstName, lastName]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !full.isEmpty { return full }
        if let email, let at = email.firstIndex(of: "@"), at != email.startIndex {
            return String(email[..<at])
        }
        return "You"
    }

    /// Your own current + closed-previous period totals from local history,
    /// shaped like server rows so the same ranking/UI path renders them.
    nonisolated static func localPreviewPlayers(entries: [DictationEntry], id: String, name: String,
                                                calendar: Calendar = .current, now: Date = Date())
        -> (daily: BackendLeaderboardPlayer, weekly: BackendLeaderboardPlayer, monthly: BackendLeaderboardPlayer,
            previousDaily: BackendLeaderboardPlayer, previousWeekly: BackendLeaderboardPlayer,
            previousMonthly: BackendLeaderboardPlayer)
    {
        let completed = entries.filter(\.isTranscribed)
        let today = calendar.startOfDay(for: now)
        let activeDays = Set(completed.map { calendar.startOfDay(for: $0.date) })
        let streak = TeamGamification.streak(days: activeDays, endingAt: today, calendar: calendar)

        func player(in interval: DateInterval) -> BackendLeaderboardPlayer {
            var words = 0, count = 0
            for entry in completed where interval.contains(entry.date) {
                words += entry.wordCount
                count += 1
            }
            return BackendLeaderboardPlayer(id: id, name: name, words: words,
                                            dictations: count, streakDays: streak)
        }

        return (
            daily: player(in: interval(for: .daily, calendar: calendar, now: now)),
            weekly: player(in: interval(for: .weekly, calendar: calendar, now: now)),
            monthly: player(in: interval(for: .monthly, calendar: calendar, now: now)),
            previousDaily: player(in: previousInterval(for: .daily, calendar: calendar, now: now)),
            previousWeekly: player(in: previousInterval(for: .weekly, calendar: calendar, now: now)),
            previousMonthly: player(in: previousInterval(for: .monthly, calendar: calendar, now: now))
        )
    }

    nonisolated static func interval(for period: Period, calendar: Calendar = .current, now: Date = Date()) -> DateInterval {
        switch period {
        case .daily:
            let start = calendar.startOfDay(for: now)
            return DateInterval(start: start, end: now)
        case .weekly:
            let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
            return DateInterval(start: start, end: now)
        case .monthly:
            let start = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
            return DateInterval(start: start, end: now)
        }
    }

    /// The fully-closed period before the current one (yesterday / last week /
    /// last month) — what rank deltas and trends compare against.
    nonisolated static func previousInterval(for period: Period, calendar: Calendar = .current, now: Date = Date()) -> DateInterval {
        let currentStart = interval(for: period, calendar: calendar, now: now).start
        let component: Calendar.Component = switch period {
        case .daily: .day
        case .weekly: .weekOfYear
        case .monthly: .month
        }
        let previousStart = calendar.date(byAdding: component, value: -1, to: currentStart) ?? currentStart
        return DateInterval(start: previousStart, end: currentStart)
    }

    nonisolated static func withDevPreviewTeammates(_ players: [BackendLeaderboardPlayer],
                                                    period: Period,
                                                    fallbackYou: BackendLeaderboardPlayer,
                                                    enabled: Bool) -> [BackendLeaderboardPlayer] {
        guard enabled else { return players }
        let base = players.isEmpty ? [fallbackYou] : players
        let existingIDs = Set(base.map(\.id))
        return base + devPreviewTeammates(for: period).filter { !existingIDs.contains($0.id) }
    }

    /// Same augmentation for the closed previous boards, so rank deltas, the
    /// team trend and the movers row can be reviewed before the server ships.
    /// Returns nil (no comparative UI) when disabled and the server sent nothing.
    nonisolated static func withDevPreviewPreviousTeammates(_ players: [BackendLeaderboardPlayer]?,
                                                            period: Period,
                                                            fallbackYou: BackendLeaderboardPlayer,
                                                            enabled: Bool) -> [BackendLeaderboardPlayer]? {
        guard enabled else { return players }
        let base = (players?.isEmpty ?? true) ? [fallbackYou] : players!
        let existingIDs = Set(base.map(\.id))
        return base + devPreviewPreviousTeammates(for: period).filter { !existingIDs.contains($0.id) }
    }

    /// The dev crew one period earlier — word totals shuffled against the
    /// current boards so several people climb, several drop, and one obvious
    /// "most improved" emerges on every period.
    nonisolated static func devPreviewPreviousTeammates(for period: Period) -> [BackendLeaderboardPlayer] {
        let words: [Int]
        let dictations: [Int]
        switch period {
        case .daily:
            words = [1_500, 900, 480, 950, 800, 300, 560, 110, 420, 350, 60, 200, 90, 0]
            dictations = [12, 7, 4, 8, 7, 3, 5, 1, 4, 3, 1, 2, 1, 0]
        case .weekly:
            words = [16_800, 16_200, 9_400, 12_500, 10_800, 5_200, 7_600, 6_900, 3_300, 4_700, 900, 3_100, 2_300, 0]
            dictations = [52, 47, 28, 37, 33, 18, 26, 24, 12, 18, 4, 12, 9, 0]
        case .monthly:
            words = [60_100, 61_500, 40_200, 50_800, 30_500, 35_800, 22_100, 26_700, 15_900, 19_800, 8_200, 12_400, 5_600, 1_800]
            dictations = [175, 181, 116, 149, 92, 104, 66, 81, 49, 61, 26, 39, 18, 6]
        }
        return devPreviewTeammates(for: period).enumerated().map { index, player in
            BackendLeaderboardPlayer(id: player.id, name: player.name, words: words[index],
                                     dictations: dictations[index],
                                     streakDays: max(0, player.streakDays - 1))
        }
    }

    nonisolated static func devPreviewTeammates(for period: Period) -> [BackendLeaderboardPlayer] {
        let names = [
            "Anna Bondar", "Dmytro Lahoda", "Mila Kovalenko", "Roman Shevchenko",
            "Oleh Martynenko", "Nina Kravets", "Taras Danyliuk", "Ira Melnyk",
            "Yurii Sokolov", "Lena Hrytsenko", "Max Levin", "Sofia Koval",
            "Andrii Honchar", "Kate Moroz",
        ]
        let words: [Int]
        let dictations: [Int]
        switch period {
        case .daily:
            words = [1_420, 1_180, 960, 840, 710, 620, 540, 460, 390, 320, 260, 180, 120, 70]
            dictations = [11, 9, 8, 7, 6, 6, 5, 4, 4, 3, 3, 2, 2, 1]
        case .weekly:
            words = [18_120, 15_640, 14_110, 12_090, 9_870, 8_500, 7_300, 6_200, 5_100, 4_300, 3_600, 2_700, 1_900, 940]
            dictations = [58, 44, 39, 36, 31, 27, 25, 22, 19, 17, 14, 11, 8, 5]
        case .monthly:
            words = [64_200, 58_900, 52_300, 47_100, 39_800, 33_200, 28_700, 24_900, 20_400, 17_600, 13_800, 10_500, 7_900, 4_200]
            dictations = [188, 165, 149, 132, 118, 96, 84, 76, 63, 52, 41, 32, 24, 14]
        }
        return names.enumerated().map { index, name in
            BackendLeaderboardPlayer(
                id: "dev-preview-\(index + 1)",
                name: name,
                words: words[index],
                dictations: dictations[index],
                streakDays: [12, 9, 7, 6, 5, 5, 4, 4, 3, 3, 2, 2, 1, 0][index])
        }
    }
}
