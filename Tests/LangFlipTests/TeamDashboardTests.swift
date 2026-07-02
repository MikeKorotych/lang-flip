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

    func testRankingSortsByXPAndFlagsYou() {
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

    func testRankingBreaksXPTiesByWordsThenName() {
        // Same XP: 100 words == 5 dictations (5 × 20).
        let words = BackendLeaderboardPlayer(id: "w", name: "Zed", words: 100, dictations: 0, streakDays: 0)
        let dictations = BackendLeaderboardPlayer(id: "d", name: "Amy", words: 0, dictations: 5, streakDays: 0)
        let ranked = TeamGamification.ranked([dictations, words], yourID: nil)
        XCTAssertEqual(ranked.map(\.player.id), ["w", "d"], "more raw words wins the tie")

        // Fully tied: alphabetical for stability.
        let a = BackendLeaderboardPlayer(id: "1", name: "Beta", words: 50, dictations: 1, streakDays: 0)
        let b = BackendLeaderboardPlayer(id: "2", name: "Alpha", words: 50, dictations: 1, streakDays: 0)
        XCTAssertEqual(TeamGamification.ranked([a, b], yourID: nil).map(\.player.name), ["Alpha", "Beta"])
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
        XCTAssertEqual(preview.daily.id, "me")
        XCTAssertEqual(preview.weekly.name, "Mike")
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
