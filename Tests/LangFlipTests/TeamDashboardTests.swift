import XCTest
@testable import LangFlip

final class TeamDashboardTests: XCTestCase {
    // MARK: Access gate

    func testEligibleForExactCorporateDomain() {
        XCTAssertTrue(TeamAccess.isEligible(email: "mykhailo.korotych@uni.tech"))
        XCTAssertTrue(TeamAccess.isEligible(email: "Someone@UNI.TECH"))
        XCTAssertTrue(TeamAccess.isEligible(email: "  padded@uni.tech \n"))
    }

    func testIneligibleForLookalikeAndForeignDomains() {
        XCTAssertFalse(TeamAccess.isEligible(email: nil))
        XCTAssertFalse(TeamAccess.isEligible(email: ""))
        XCTAssertFalse(TeamAccess.isEligible(email: "user@gmail.com"))
        XCTAssertFalse(TeamAccess.isEligible(email: "user@notuni.tech"))
        XCTAssertFalse(TeamAccess.isEligible(email: "user@mail.uni.tech"))
        XCTAssertFalse(TeamAccess.isEligible(email: "uni.tech@gmail.com"))
        XCTAssertFalse(TeamAccess.isEligible(email: "uni.tech"))
    }

    // MARK: XP / levels

    func testXPFormula() {
        XCTAssertEqual(TeamGamification.xp(words: 0, dictations: 0, streakDays: 0), 0)
        XCTAssertEqual(TeamGamification.xp(words: 100, dictations: 3, streakDays: 2),
                       100 + 3 * TeamGamification.dictationBonus + 2 * TeamGamification.streakDayBonus)
        // Negative inputs (impossible, but defensive) never produce negative XP.
        XCTAssertEqual(TeamGamification.xp(words: -5, dictations: -1, streakDays: -1), 0)
    }

    func testLevelBoundaries() {
        XCTAssertEqual(TeamGamification.level(forXP: 0), 1)
        XCTAssertEqual(TeamGamification.level(forXP: 499), 1)
        XCTAssertEqual(TeamGamification.level(forXP: 500), 2)   // floor(L2) = 250·2·1
        XCTAssertEqual(TeamGamification.level(forXP: 1_499), 2)
        XCTAssertEqual(TeamGamification.level(forXP: 1_500), 3) // floor(L3) = 250·3·2
    }

    func testLevelIsMonotonicInXP() {
        var previous = 0
        for xp in stride(from: 0, through: 50_000, by: 250) {
            let level = TeamGamification.level(forXP: xp)
            XCTAssertGreaterThanOrEqual(level, previous)
            previous = level
        }
    }

    func testProgressToNextLevelStaysInUnitRange() {
        for xp in [0, 1, 499, 500, 12_345, 1_000_000] {
            let progress = TeamGamification.progressToNextLevel(forXP: xp)
            XCTAssertGreaterThanOrEqual(progress, 0, "xp \(xp)")
            XCTAssertLessThan(progress, 1, "xp \(xp)")
        }
    }

    func testLevelTitleClampsToKnownRange() {
        XCTAssertEqual(TeamGamification.title(forLevel: 0), TeamGamification.levelTitles.first)
        XCTAssertEqual(TeamGamification.title(forLevel: 1), TeamGamification.levelTitles.first)
        XCTAssertEqual(TeamGamification.title(forLevel: 999), TeamGamification.levelTitles.last)
    }

    // MARK: Ranking

    func testRankingSortsByWordsAndFlagsYou() {
        let players = [
            BackendLeaderboardPlayer(id: "a", name: "Alice", words: 100, dictations: 0, streakDays: 0),
            BackendLeaderboardPlayer(id: "b", name: "Bob", words: 900, dictations: 0, streakDays: 0),
            BackendLeaderboardPlayer(id: "c", name: "Carol", words: 500, dictations: 0, streakDays: 0),
        ]
        let ranked = TeamGamification.ranked(players, yourID: "c")
        XCTAssertEqual(ranked.map(\.player.id), ["b", "c", "a"])
        XCTAssertEqual(ranked.map(\.rank), [1, 2, 3])
        XCTAssertEqual(ranked.filter(\.isYou).map(\.player.id), ["c"])
    }

    func testRankingBreaksWordTiesByDictationsStreakThenName() {
        let frequent = BackendLeaderboardPlayer(id: "f", name: "Frequent", words: 100, dictations: 5, streakDays: 0)
        let burst = BackendLeaderboardPlayer(id: "b", name: "Burst", words: 100, dictations: 1, streakDays: 0)
        XCTAssertEqual(TeamGamification.ranked([burst, frequent], yourID: nil).map(\.player.id), ["f", "b"])

        let streak = BackendLeaderboardPlayer(id: "s", name: "Streak", words: 50, dictations: 1, streakDays: 7)
        let quiet = BackendLeaderboardPlayer(id: "q", name: "Quiet", words: 50, dictations: 1, streakDays: 0)
        XCTAssertEqual(TeamGamification.ranked([quiet, streak], yourID: nil).map(\.player.id), ["s", "q"])

        let a = BackendLeaderboardPlayer(id: "1", name: "Beta", words: 50, dictations: 1, streakDays: 0)
        let b = BackendLeaderboardPlayer(id: "2", name: "Alpha", words: 50, dictations: 1, streakDays: 0)
        XCTAssertEqual(TeamGamification.ranked([a, b], yourID: nil).map(\.player.name), ["Alpha", "Beta"])
    }

    // MARK: Board insights

    private func player(_ id: String, _ words: Int, dictations: Int = 0, streak: Int = 0) -> BackendLeaderboardPlayer {
        BackendLeaderboardPlayer(id: id, name: id.capitalized, words: words,
                                 dictations: dictations, streakDays: streak)
    }

    func testTeamPulseTotalsAndTrend() {
        let current = TeamGamification.ranked([
            player("a", 1_000), player("b", 500), player("c", 0),
        ], yourID: nil)
        let insights = TeamGamification.insights(
            current: current,
            previous: [player("a", 800), player("b", 200)])

        XCTAssertEqual(insights.pulse.totalWords, 1_500)
        XCTAssertEqual(insights.pulse.activeMembers, 2, "zero-word players are not active")
        XCTAssertEqual(insights.pulse.averageWords, 750)
        XCTAssertEqual(insights.pulse.previousTotalWords, 1_000)
        XCTAssertEqual(insights.pulse.trendPercent, 50)
    }

    func testTeamPulseTrendHiddenWithoutComparablePrevious() {
        let current = TeamGamification.ranked([player("a", 100)], yourID: nil)
        XCTAssertNil(TeamGamification.insights(current: current, previous: nil).pulse.trendPercent)
        XCTAssertNil(TeamGamification.insights(current: current, previous: []).pulse.trendPercent,
                     "empty previous board (0 words) has no meaningful percent base")
    }

    func testYourStandingDeltaAndGaps() {
        // Current: a 900, b 700, c 650, d 600, e 550, you 400 (#6).
        let current = TeamGamification.ranked([
            player("a", 900), player("b", 700), player("c", 650),
            player("d", 600), player("e", 550), player("you", 400),
        ], yourID: "you")
        // Previously you were #8 of the same crowd (lower words).
        let previous = [
            player("a", 800), player("b", 700), player("c", 600), player("d", 500),
            player("e", 450), player("x", 300), player("z", 200), player("you", 100),
        ]
        let you = try! XCTUnwrap(TeamGamification.insights(current: current, previous: previous).you)

        XCTAssertEqual(you.rank, 6)
        XCTAssertEqual(you.totalPlayers, 6)
        XCTAssertEqual(you.rankDelta, 2, "was #8, now #6")
        XCTAssertEqual(you.gapToNext, 150, "words behind #5 (e, 550)")
        XCTAssertEqual(you.gapToTopFive, 150, "rank 6 → gap to #5 is also the top-five gap")
        XCTAssertNil(you.leadOverNext)
    }

    func testYourStandingWhenLeading() {
        let current = TeamGamification.ranked([
            player("you", 900), player("b", 640),
        ], yourID: "you")
        let you = try! XCTUnwrap(TeamGamification.insights(current: current, previous: nil).you)

        XCTAssertEqual(you.rank, 1)
        XCTAssertNil(you.gapToNext)
        XCTAssertNil(you.gapToTopFive)
        XCTAssertEqual(you.leadOverNext, 260)
        XCTAssertNil(you.rankDelta, "no previous board → no movement chip")
    }

    func testRankDeltasAndNewEntrants() {
        let current = TeamGamification.ranked([
            player("a", 900), player("b", 700), player("new", 650),
        ], yourID: nil)
        let previous = [player("b", 900), player("a", 700)]
        let insights = TeamGamification.insights(current: current, previous: previous)

        XCTAssertEqual(insights.rankDeltas["a"], 1, "climbed 2 → 1")
        XCTAssertEqual(insights.rankDeltas["b"], -1, "dropped 1 → 2")
        XCTAssertNil(insights.rankDeltas["new"], "absent from the previous board")
    }

    func testMoversPickBiggestClimbAndLargestGrowth() {
        // climber: was #4 → #2 (+2); "a" stays #1; "new" enters at #3.
        let current = TeamGamification.ranked([
            player("a", 1_000), player("climber", 900), player("new", 800), player("b", 700),
        ], yourID: nil)
        let previous = [
            player("a", 950), player("b", 800), player("x", 500), player("climber", 400),
        ]
        let insights = TeamGamification.insights(current: current, previous: previous)

        XCTAssertEqual(insights.topClimber?.player.id, "climber")
        XCTAssertEqual(insights.topClimber?.rankClimb, 2)
        XCTAssertEqual(insights.topClimber?.wordsGained, 500)
        // Most improved counts new entrants from zero: new gained 800 > climber's 500.
        XCTAssertEqual(insights.mostImproved?.player.id, "new")
        XCTAssertEqual(insights.mostImproved?.wordsGained, 800)
    }

    func testMoversAbsentWithoutPreviousBoard() {
        let current = TeamGamification.ranked([player("a", 100), player("b", 50)], yourID: nil)
        let insights = TeamGamification.insights(current: current, previous: nil)
        XCTAssertNil(insights.topClimber)
        XCTAssertNil(insights.mostImproved)
        XCTAssertTrue(insights.rankDeltas.isEmpty)
    }

    // MARK: Badges

    func testBadgeUnlocks() {
        var input = TeamGamification.BadgeInputs()
        var unlocked = Set(TeamGamification.badges(input).filter(\.unlocked).map(\.id))
        XCTAssertTrue(unlocked.isEmpty)

        input.totalDictations = 1
        input.totalWords = 10_000
        input.longestStreak = 7
        input.maxWordsInOneDictation = 500
        input.hasDictationBefore8am = true
        unlocked = Set(TeamGamification.badges(input).filter(\.unlocked).map(\.id))
        XCTAssertEqual(unlocked, ["first-words", "wordsmith", "novelist",
                                  "warming-up", "on-fire", "marathon", "early-bird"])
    }

    func testBadgeInputsFromHistory() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 2, hour: 12)))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now))
        let lateEntry = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 23)))

        let entries = [
            DictationEntry(text: "three words here", date: now),
            DictationEntry(text: "one two", date: yesterday),
            DictationEntry(text: "night words", date: lateEntry),
            DictationEntry(text: "should not count", date: now, status: .failed),
        ]
        let input = TeamGamification.badgeInputs(entries: entries, calendar: calendar, now: now)
        XCTAssertEqual(input.totalDictations, 3)
        XCTAssertEqual(input.totalWords, 7)
        XCTAssertEqual(input.maxWordsInOneDictation, 3)
        XCTAssertEqual(input.currentStreak, 2)
        XCTAssertEqual(input.longestStreak, 2)
        XCTAssertTrue(input.hasDictationAfter10pm)
        XCTAssertFalse(input.hasDictationBefore8am)
    }

    // MARK: DTO decoding

    func testLeaderboardResponseDecodesServerShape() throws {
        let json = """
        {
          "daily": [
            { "id": "u1", "name": "Mila", "words": 320, "dictations": 4, "streakDays": 6 }
          ],
          "weekly": [],
          "generatedAt": "2026-07-02T10:00:00.000Z"
        }
        """.data(using: .utf8)!
        let response = try BackendJSON.decoder.decode(BackendLeaderboardResponse.self, from: json)
        XCTAssertEqual(response.daily, [BackendLeaderboardPlayer(id: "u1", name: "Mila", words: 320,
                                                                 dictations: 4, streakDays: 6)])
        XCTAssertTrue(response.weekly.isEmpty)
        XCTAssertNil(response.monthly)
    }

    func testLeaderboardResponseDecodesOptionalMonthlyBoard() throws {
        let json = """
        {
          "daily": [],
          "weekly": [],
          "monthly": [
            { "id": "u1", "name": "Mila", "words": 1200, "dictations": 12, "streakDays": 6 }
          ],
          "generatedAt": "2026-07-02T10:00:00.000Z"
        }
        """.data(using: .utf8)!
        let response = try BackendJSON.decoder.decode(BackendLeaderboardResponse.self, from: json)
        XCTAssertEqual(response.monthly, [BackendLeaderboardPlayer(id: "u1", name: "Mila", words: 1200,
                                                                   dictations: 12, streakDays: 6)])
    }

    // MARK: Local preview

    func testLocalPreviewAggregatesTodayAndWeek() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        // Wednesday — the ISO week began Monday June 29.
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 15)))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 9)))
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 29, hour: 10)))
        let lastWeek = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 20, hour: 10)))

        let entries = [
            DictationEntry(text: "a b c", date: today),          // 3 words — today + week
            DictationEntry(text: "d e", date: monday),           // 2 words — week only
            DictationEntry(text: "x y z w", date: lastWeek),     // outside the week
        ]
        let preview = TeamDashboardModel.localPreviewPlayers(
            entries: entries, id: "me", name: "Mike", calendar: calendar, now: now)

        XCTAssertEqual(preview.daily.words, 3)
        XCTAssertEqual(preview.daily.dictations, 1)
        XCTAssertEqual(preview.weekly.words, 5)
        XCTAssertEqual(preview.weekly.dictations, 2)
        XCTAssertEqual(preview.monthly.words, 3)
        XCTAssertEqual(preview.monthly.dictations, 1)
        XCTAssertEqual(preview.daily.id, "me")
        XCTAssertEqual(preview.weekly.name, "Mike")
    }

    func testActivitySummaryCountsPeriodOnly() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 12)))
        let dayOne = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 9)))
        let dayTwo = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 2, hour: 9)))
        let lastMonth = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 30, hour: 9)))
        let interval = TeamDashboardModel.interval(for: .monthly, calendar: calendar, now: now)
        let summary = TeamGamification.activitySummary(entries: [
            DictationEntry(text: "a b c", date: dayOne),
            DictationEntry(text: "d e", date: dayOne),
            DictationEntry(text: "f g h i", date: dayTwo),
            DictationEntry(text: "outside period", date: lastMonth),
            DictationEntry(text: "failed words", date: dayTwo, status: .failed),
        ], interval: interval, calendar: calendar)

        XCTAssertEqual(summary.words, 9)
        XCTAssertEqual(summary.dictations, 3)
        XCTAssertEqual(summary.activeDays, 2)
        XCTAssertEqual(summary.bestDayWords, 5)
        XCTAssertEqual(summary.averageWordsPerActiveDay, 5)
    }

    func testLocalPreviewAggregatesClosedPreviousPeriods() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        // Wednesday July 1; current week began Monday June 29, last week June 22–28.
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 15)))
        let yesterday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 30, hour: 10)))
        let lastWeek = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 24, hour: 10)))
        let lastMonth = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 10)))

        let entries = [
            DictationEntry(text: "a b c", date: now),            // current everything
            DictationEntry(text: "d e", date: yesterday),        // prev day, current week+month? (June 30 = current week, prev month)
            DictationEntry(text: "f g h i", date: lastWeek),     // prev week, prev month
            DictationEntry(text: "j", date: lastMonth),          // prev month only
        ]
        let preview = TeamDashboardModel.localPreviewPlayers(
            entries: entries, id: "me", name: "Mike", calendar: calendar, now: now)

        XCTAssertEqual(preview.previousDaily.words, 2, "yesterday only")
        XCTAssertEqual(preview.previousWeekly.words, 4, "last ISO week only")
        XCTAssertEqual(preview.previousMonthly.words, 7, "all of June")
        XCTAssertEqual(preview.monthly.words, 3, "July so far")
    }

    func testDevPreviewPreviousTeammatesMirrorTheCrew() {
        let you = BackendLeaderboardPlayer(id: "me", name: "Mike", words: 10, dictations: 1, streakDays: 1)
        XCTAssertNil(TeamDashboardModel.withDevPreviewPreviousTeammates(nil, period: .weekly,
                                                                        fallbackYou: you, enabled: false),
                     "disabled + no server data → no comparative UI")

        let previous = try! XCTUnwrap(TeamDashboardModel.withDevPreviewPreviousTeammates(
            nil, period: .weekly, fallbackYou: you, enabled: true))
        XCTAssertEqual(previous.first, you)
        let currentIDs = Set(TeamDashboardModel.devPreviewTeammates(for: .weekly).map(\.id))
        XCTAssertEqual(Set(previous.dropFirst().map(\.id)), currentIDs,
                       "previous board covers the same synthetic crew")
    }

    func testLeaderboardResponseDecodesOptionalPreviousBoards() throws {
        let json = """
        {
          "daily": [], "weekly": [],
          "previousWeekly": [
            { "id": "u1", "name": "Mila", "words": 900, "dictations": 9, "streakDays": 3 }
          ],
          "generatedAt": "2026-07-02T10:00:00.000Z"
        }
        """.data(using: .utf8)!
        let response = try BackendJSON.decoder.decode(BackendLeaderboardResponse.self, from: json)
        XCTAssertNil(response.previousDaily)
        XCTAssertEqual(response.previousWeekly?.count, 1)
        XCTAssertNil(response.previousMonthly)
    }

    func testDevPreviewTeammatesAreOptInOnly() {
        let you = BackendLeaderboardPlayer(id: "me", name: "Mike", words: 250, dictations: 4, streakDays: 2)
        XCTAssertEqual(
            TeamDashboardModel.withDevPreviewTeammates([you], period: .weekly, fallbackYou: you, enabled: false),
            [you])

        let preview = TeamDashboardModel.withDevPreviewTeammates([you], period: .weekly,
                                                                 fallbackYou: you, enabled: true)
        XCTAssertGreaterThan(preview.count, 10)
        XCTAssertEqual(preview.first, you)
        XCTAssertTrue(preview.contains { $0.id.hasPrefix("dev-preview-") })
    }

    func testDevPreviewTeammatesUseFallbackWhenBaseRowsAreEmpty() {
        let you = BackendLeaderboardPlayer(id: "me", name: "Mike", words: 0, dictations: 0, streakDays: 0)
        let preview = TeamDashboardModel.withDevPreviewTeammates([], period: .daily,
                                                                 fallbackYou: you, enabled: true)
        XCTAssertEqual(preview.first, you)
        XCTAssertGreaterThan(preview.count, 10)
    }

    func testDisplayNameFallsBackToEmailLocalPart() {
        XCTAssertEqual(TeamDashboardModel.displayName(email: "mila.k@uni.tech",
                                                      firstName: "", lastName: ""), "mila.k")
        XCTAssertEqual(TeamDashboardModel.displayName(email: "mila.k@uni.tech",
                                                      firstName: "Mila", lastName: "K"), "Mila K")
        XCTAssertEqual(TeamDashboardModel.displayName(email: nil,
                                                      firstName: "", lastName: ""), "You")
    }
}
