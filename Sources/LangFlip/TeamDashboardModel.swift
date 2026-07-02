import Foundation

/// State for the Team dashboard. Tries the backend leaderboard first; when the
/// endpoint is unavailable (not deployed yet, offline, signed out mid-view) it
/// degrades to a "preview" board built from the local dictation history — your
/// own row only, never invented teammates. Badges are always computed locally:
/// they describe *your* habits and need no server.
@MainActor
final class TeamDashboardModel: ObservableObject {
    enum Source: Equatable {
        case live(generatedAt: Date)
        case localPreview
    }

    enum Period: String, CaseIterable {
        case daily = "Today"
        case weekly = "This Week"
    }

    @Published private(set) var daily: [TeamGamification.RankedPlayer] = []
    @Published private(set) var weekly: [TeamGamification.RankedPlayer] = []
    @Published private(set) var badges: [TeamGamification.Badge] = []
    @Published private(set) var source: Source = .localPreview
    @Published private(set) var isLoading = false

    private let client: HTTPBackendClient
    private let history: DictationHistory
    private let auth: SupabaseBackendAuth

    init(client: HTTPBackendClient = .shared,
         history: DictationHistory = .shared,
         auth: SupabaseBackendAuth = .shared) {
        self.client = client
        self.history = history
        self.auth = auth
    }

    func rows(for period: Period) -> [TeamGamification.RankedPlayer] {
        period == .daily ? daily : weekly
    }

    var you: TeamGamification.RankedPlayer? { weekly.first(where: \.isYou) }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        badges = TeamGamification.badges(TeamGamification.badgeInputs(entries: history.entries))

        let yourID = auth.currentUser?.id
        do {
            let response = try await client.leaderboard()
            daily = TeamGamification.ranked(response.daily, yourID: yourID)
            weekly = TeamGamification.ranked(response.weekly, yourID: yourID)
            source = .live(generatedAt: response.generatedAt)
        } catch {
            let preview = Self.localPreviewPlayers(
                entries: history.entries,
                id: yourID ?? "local",
                name: Self.displayName(email: auth.currentUser?.email,
                                       firstName: Settings.shared.accountFirstName,
                                       lastName: Settings.shared.accountLastName))
            daily = TeamGamification.ranked([preview.daily], yourID: preview.daily.id)
            weekly = TeamGamification.ranked([preview.weekly], yourID: preview.weekly.id)
            source = .localPreview
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

    /// Your own daily/weekly totals from local history, shaped like server rows
    /// so the same ranking/UI path renders them.
    nonisolated static func localPreviewPlayers(entries: [DictationEntry], id: String, name: String,
                                                calendar: Calendar = .current, now: Date = Date())
        -> (daily: BackendLeaderboardPlayer, weekly: BackendLeaderboardPlayer)
    {
        let completed = entries.filter(\.isTranscribed)
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today

        var dayWords = 0, dayCount = 0, weekWords = 0, weekCount = 0
        var activeDays = Set<Date>()
        for entry in completed {
            let words = entry.wordCount
            if calendar.startOfDay(for: entry.date) == today {
                dayWords += words
                dayCount += 1
            }
            if entry.date >= weekStart && entry.date <= now {
                weekWords += words
                weekCount += 1
            }
            activeDays.insert(calendar.startOfDay(for: entry.date))
        }
        let streak = TeamGamification.streak(days: activeDays, endingAt: today, calendar: calendar)

        return (
            daily: BackendLeaderboardPlayer(id: id, name: name, words: dayWords,
                                            dictations: dayCount, streakDays: streak),
            weekly: BackendLeaderboardPlayer(id: id, name: name, words: weekWords,
                                             dictations: weekCount, streakDays: streak)
        )
    }
}
