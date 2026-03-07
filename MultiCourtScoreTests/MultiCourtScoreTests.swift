//
//  MultiCourtScoreTests.swift
//  MultiCourtScoreTests
//
//  Comprehensive unit tests for MultiCourtScore
//

import Testing
import Foundation
import Darwin
@testable import MultiCourtScore

// MARK: - ScoreSnapshot Tests

struct ScoreSnapshotTests {

    // MARK: hasStarted

    @Test func hasStarted_isTrue_whenStatusIsInProgress() async throws {
        let snapshot = makeSnapshot(status: "In Progress")
        #expect(snapshot.hasStarted)
    }

    @Test func hasStarted_isTrue_whenStatusContainsLive() async throws {
        let snapshot = makeSnapshot(status: "Live")
        #expect(snapshot.hasStarted)
    }

    @Test func hasStarted_isTrue_whenStatusContainsPlaying() async throws {
        let snapshot = makeSnapshot(status: "Playing")
        #expect(snapshot.hasStarted)
    }

    @Test func hasStarted_isTrue_whenStatusIsFinal() async throws {
        let snapshot = makeSnapshot(status: "Final")
        #expect(snapshot.hasStarted)
    }

    @Test func hasStarted_isTrue_whenScoresExist() async throws {
        let snapshot = makeSnapshot(status: "Pre-Match", team1Score: 7, team2Score: 6)
        #expect(snapshot.hasStarted)
    }

    @Test func hasStarted_isTrue_whenSetNumberGreaterThan1() async throws {
        let snapshot = makeSnapshot(status: "Pre-Match", setNumber: 2)
        #expect(snapshot.hasStarted)
    }

    @Test func hasStarted_isTrue_whenSetHistoryHasScores() async throws {
        let snapshot = makeSnapshot(
            status: "Pre-Match",
            setHistory: [SetScore(setNumber: 1, team1Score: 5, team2Score: 3, isComplete: false)]
        )
        #expect(snapshot.hasStarted)
    }

    @Test func hasStarted_isFalse_whenPreMatchAndNoScores() async throws {
        let snapshot = makeSnapshot(status: "Pre-Match")
        #expect(!snapshot.hasStarted)
    }

    @Test func hasStarted_isFalse_whenWaiting() async throws {
        let snapshot = makeSnapshot(status: "Waiting")
        #expect(!snapshot.hasStarted)
    }

    // MARK: isFinal

    @Test func isFinal_isTrue_whenStatusIsFinal() async throws {
        let snapshot = makeSnapshot(status: "Final")
        #expect(snapshot.isFinal)
    }

    @Test func isFinal_isTrue_whenTeam1WinsEnoughSets_bestOf3() async throws {
        let snapshot = makeSnapshot(
            status: "In Progress",
            setHistory: [
                SetScore(setNumber: 1, team1Score: 21, team2Score: 15, isComplete: true),
                SetScore(setNumber: 2, team1Score: 21, team2Score: 18, isComplete: true)
            ],
            setsToWin: 2
        )
        #expect(snapshot.isFinal)
    }

    @Test func isFinal_isTrue_whenTeam2WinsEnoughSets_bestOf3() async throws {
        let snapshot = makeSnapshot(
            status: "In Progress",
            setHistory: [
                SetScore(setNumber: 1, team1Score: 15, team2Score: 21, isComplete: true),
                SetScore(setNumber: 2, team1Score: 18, team2Score: 21, isComplete: true)
            ],
            setsToWin: 2
        )
        #expect(snapshot.isFinal)
    }

    @Test func isFinal_isFalse_whenSplit1_1_bestOf3() async throws {
        let snapshot = makeSnapshot(
            status: "In Progress",
            setNumber: 3,
            setHistory: [
                SetScore(setNumber: 1, team1Score: 21, team2Score: 15, isComplete: true),
                SetScore(setNumber: 2, team1Score: 15, team2Score: 21, isComplete: true)
            ],
            setsToWin: 2
        )
        #expect(!snapshot.isFinal)
    }

    @Test func isFinal_isTrue_forSingleSetMatch() async throws {
        let snapshot = makeSnapshot(
            status: "In Progress",
            setHistory: [
                SetScore(setNumber: 1, team1Score: 28, team2Score: 22, isComplete: true)
            ],
            setsToWin: 1
        )
        #expect(snapshot.isFinal)
    }

    @Test func isFinal_isFalse_forSingleSetInProgress() async throws {
        let snapshot = makeSnapshot(
            status: "In Progress",
            setHistory: [
                SetScore(setNumber: 1, team1Score: 20, team2Score: 19, isComplete: false)
            ],
            setsToWin: 1
        )
        #expect(!snapshot.isFinal)
    }

    // MARK: totalSetsWon

    @Test func totalSetsWon_countsCorrectly() async throws {
        let snapshot = makeSnapshot(
            setHistory: [
                SetScore(setNumber: 1, team1Score: 21, team2Score: 15, isComplete: true),
                SetScore(setNumber: 2, team1Score: 15, team2Score: 21, isComplete: true),
                SetScore(setNumber: 3, team1Score: 15, team2Score: 10, isComplete: true)
            ]
        )
        let won = snapshot.totalSetsWon
        #expect(won.team1 == 2)
        #expect(won.team2 == 1)
    }

    @Test func totalSetsWon_ignoresIncompleteSets() async throws {
        let snapshot = makeSnapshot(
            setHistory: [
                SetScore(setNumber: 1, team1Score: 21, team2Score: 15, isComplete: true),
                SetScore(setNumber: 2, team1Score: 10, team2Score: 8, isComplete: false)
            ]
        )
        let won = snapshot.totalSetsWon
        #expect(won.team1 == 1)
        #expect(won.team2 == 0)
    }

    @Test func totalSetsWon_tiedSetDoesNotCountAsWin() async throws {
        // Edge case: tied set (shouldn't happen in volleyball but verify no crash)
        let snapshot = makeSnapshot(
            setHistory: [
                SetScore(setNumber: 1, team1Score: 21, team2Score: 21, isComplete: true)
            ]
        )
        let won = snapshot.totalSetsWon
        #expect(won.team1 == 0)
        #expect(won.team2 == 0)
    }

    @Test func totalSetsWon_emptyHistory() async throws {
        let snapshot = makeSnapshot(setHistory: [])
        let won = snapshot.totalSetsWon
        #expect(won.team1 == 0)
        #expect(won.team2 == 0)
    }

    // MARK: empty factory

    @Test func empty_returnsDefaultValues() async throws {
        let snapshot = ScoreSnapshot.empty(courtId: 5)
        #expect(snapshot.courtId == 5)
        #expect(snapshot.status == "Waiting")
        #expect(snapshot.team1Score == 0)
        #expect(snapshot.team2Score == 0)
        #expect(snapshot.setHistory.isEmpty)
        #expect(snapshot.setsToWin == 2)
    }
}

// MARK: - SetScore Tests

struct SetScoreTests {
    @Test func displayString_formatsCorrectly() async throws {
        let set = SetScore(setNumber: 1, team1Score: 21, team2Score: 18, isComplete: true)
        #expect(set.displayString == "21-18")
    }

    @Test func displayString_zeroZero() async throws {
        let set = SetScore(setNumber: 1, team1Score: 0, team2Score: 0, isComplete: false)
        #expect(set.displayString == "0-0")
    }
}

// MARK: - MatchItem Tests

struct MatchItemTests {
    @Test func displayName_showsTeamNames() async throws {
        let match = MatchItem(
            apiURL: URL(string: "https://example.com")!,
            team1Name: "Player A / Player B",
            team2Name: "Player C / Player D"
        )
        #expect(match.displayName == "Player A / Player B vs Player C / Player D")
    }

    @Test func displayName_fallsBackToLabel() async throws {
        let match = MatchItem(apiURL: URL(string: "https://example.com")!, label: "Match 5")
        #expect(match.displayName == "Match 5")
    }

    @Test func displayName_convertsNumericLabelToMatch() async throws {
        let match = MatchItem(apiURL: URL(string: "https://example.com")!, label: "7")
        #expect(match.displayName == "Match 7")
    }

    @Test func displayName_fallsBackToGeneric() async throws {
        let match = MatchItem(apiURL: URL(string: "https://example.com")!)
        #expect(match.displayName == "Match")
    }

    @Test func shortDisplayName_usesFirstNames() async throws {
        let match = MatchItem(
            apiURL: URL(string: "https://example.com")!,
            team1Name: "Nathan Hicks",
            team2Name: "Reid Malone"
        )
        #expect(match.shortDisplayName == "Nathan v Reid")
    }

    @Test func shortDisplayName_numericLabel() async throws {
        let match = MatchItem(apiURL: URL(string: "https://example.com")!, label: "12")
        #expect(match.shortDisplayName == "M12")
    }

    @Test func codable_roundTrip() async throws {
        let original = MatchItem(
            apiURL: URL(string: "https://api.volleyballlife.com/api/v1.0/matches/325750/vmix")!,
            label: "1",
            team1Name: "William Mota / Derek Strause",
            team2Name: "George Black / Daniel Wenger",
            team1Seed: "1",
            team2Seed: "4",
            matchType: "Bracket Play",
            typeDetail: "Winners Bracket",
            scheduledTime: "9:00AM",
            courtNumber: "1",
            setsToWin: 1,
            pointsPerSet: 28
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MatchItem.self, from: encoded)

        #expect(decoded.apiURL == original.apiURL)
        #expect(decoded.team1Name == original.team1Name)
        #expect(decoded.team2Name == original.team2Name)
        #expect(decoded.setsToWin == original.setsToWin)
        #expect(decoded.pointsPerSet == original.pointsPerSet)
    }
}

// MARK: - Court Tests

struct CourtTests {
    @Test func create_setsDefaults() async throws {
        let court = Court.create(id: 3)
        #expect(court.id == 3)
        #expect(court.name == "Mevo 3")
        #expect(court.queue.isEmpty)
        #expect(court.activeIndex == nil)
        #expect(court.status == .idle)
    }

    @Test func create_withCustomName() async throws {
        let court = Court.create(id: 1, name: "Main Court")
        #expect(court.name == "Main Court")
    }

    @Test func currentMatch_returnsNilWhenNoActiveIndex() async throws {
        let court = Court.create(id: 1)
        #expect(court.currentMatch == nil)
    }

    @Test func currentMatch_returnsCorrectMatch() async throws {
        var court = Court.create(id: 1)
        let match = MatchItem(apiURL: URL(string: "https://example.com")!, label: "1")
        court.queue = [match]
        court.activeIndex = 0
        #expect(court.currentMatch?.label == "1")
    }

    @Test func nextMatch_returnsNextInQueue() async throws {
        var court = Court.create(id: 1)
        let m1 = MatchItem(apiURL: URL(string: "https://example.com/1")!, label: "1")
        let m2 = MatchItem(apiURL: URL(string: "https://example.com/2")!, label: "2")
        court.queue = [m1, m2]
        court.activeIndex = 0
        #expect(court.nextMatch?.label == "2")
    }

    @Test func nextMatch_returnsNilAtEnd() async throws {
        var court = Court.create(id: 1)
        let m1 = MatchItem(apiURL: URL(string: "https://example.com/1")!, label: "1")
        court.queue = [m1]
        court.activeIndex = 0
        #expect(court.nextMatch == nil)
    }

    @Test func remainingMatchCount_correct() async throws {
        var court = Court.create(id: 1)
        let matches = (0..<5).map { i in
            MatchItem(apiURL: URL(string: "https://example.com/\(i)")!, label: "\(i)")
        }
        court.queue = matches
        court.activeIndex = 2
        #expect(court.remainingMatchCount == 2)
    }

    @Test func remainingMatchCount_noActiveIndex() async throws {
        var court = Court.create(id: 1)
        court.queue = [MatchItem(apiURL: URL(string: "https://example.com")!)]
        #expect(court.remainingMatchCount == 1)
    }

    @Test func codable_roundTrip() async throws {
        var court = Court.create(id: 2)
        court.status = .live
        court.queue = [MatchItem(apiURL: URL(string: "https://example.com")!, label: "Test")]
        court.activeIndex = 0

        let encoded = try JSONEncoder().encode(court)
        let decoded = try JSONDecoder().decode(Court.self, from: encoded)

        #expect(decoded.id == 2)
        #expect(decoded.status == .live)
        #expect(decoded.queue.count == 1)
        #expect(decoded.activeIndex == 0)
    }
}

// MARK: - CourtStatus Tests

struct CourtStatusTests {
    @Test func displayNames() async throws {
        #expect(CourtStatus.idle.displayName == "Idle")
        #expect(CourtStatus.waiting.displayName == "Waiting")
        #expect(CourtStatus.live.displayName == "Live")
        #expect(CourtStatus.finished.displayName == "Finished")
        #expect(CourtStatus.error.displayName == "Error")
    }

    @Test func isPolling_trueForActiveStates() async throws {
        #expect(CourtStatus.waiting.isPolling)
        #expect(CourtStatus.live.isPolling)
        #expect(CourtStatus.finished.isPolling)
    }

    @Test func isPolling_falseForInactiveStates() async throws {
        #expect(!CourtStatus.idle.isPolling)
        #expect(!CourtStatus.error.isPolling)
    }

    @Test func codable_roundTrip() async throws {
        for status in CourtStatus.allCases {
            let encoded = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(CourtStatus.self, from: encoded)
            #expect(decoded == status)
        }
    }
}

// MARK: - CourtNaming Tests

struct CourtNamingTests {
    @Test func defaultName_core1() async throws {
        #expect(CourtNaming.defaultName(for: 1) == "Core 1")
    }

    @Test func defaultName_mevos() async throws {
        #expect(CourtNaming.defaultName(for: 2) == "Mevo 2")
        #expect(CourtNaming.defaultName(for: 5) == "Mevo 5")
        #expect(CourtNaming.defaultName(for: 10) == "Mevo 10")
    }

    @Test func shortName_core1() async throws {
        #expect(CourtNaming.shortName(for: 1) == "C1")
    }

    @Test func shortName_mevos() async throws {
        #expect(CourtNaming.shortName(for: 2) == "M2")
        #expect(CourtNaming.shortName(for: 10) == "M10")
    }

    @Test func courtCreate_usesDefaultName() async throws {
        let court = Court.create(id: 1)
        #expect(court.displayName == "Core 1")
        let court2 = Court.create(id: 3)
        #expect(court2.displayName == "Mevo 3")
    }

    @Test func courtCreate_usesCustomName() async throws {
        let court = Court.create(id: 1, name: "My Camera")
        #expect(court.displayName == "My Camera")
    }
}

// MARK: - AppConfig Tests

struct AppConfigTests {
    @Test func maxCourts_is10() async throws {
        #expect(AppConfig.maxCourts == 10)
    }

    @Test func holdScoreDuration_is3Minutes() async throws {
        #expect(AppConfig.holdScoreDuration == 180)
    }

    @Test func staleMatchTimeout_is15Minutes() async throws {
        #expect(AppConfig.staleMatchTimeout == 900)
    }
}

// MARK: - NetworkConstants Tests

struct NetworkConstantsTests {
    @Test func port_is8787() async throws {
        #expect(NetworkConstants.webSocketPort == 8787)
    }

    @Test func pollingInterval_reasonable() async throws {
        #expect(NetworkConstants.pollingInterval >= 1.0)
        #expect(NetworkConstants.pollingInterval <= 10.0)
    }

    @Test func maxRetries_reasonable() async throws {
        #expect(NetworkConstants.maxRetries >= 1)
        #expect(NetworkConstants.maxRetries <= 10)
    }
}

// MARK: - Overlay Data Flow Tests

struct OverlayDataFlowTests {

    // Verify score.json fields match what the overlay JavaScript expects.
    // The JS uses: d.team1, d.team2, d.score1, d.score2, d.set,
    //   d.setsWon1, d.setsWon2, d.setsA, d.setsB, d.courtStatus,
    //   d.setsToWin, d.serve, d.setHistory, d.seed1, d.seed2,
    //   d.nextMatch, d.pointsPerSet, d.pointCap, d.status

    @Test func scoreJsonShape_liveMatch_hasAllRequiredFields() async throws {
        // Simulate a live match in set 2 with set 1 completed 21-18
        let snapshot = ScoreSnapshot(
            courtId: 1, matchId: 100,
            status: "In Progress", setNumber: 2,
            team1Name: "Smith / Jones", team2Name: "Brown / Davis",
            team1Seed: "1", team2Seed: "4",
            scheduledTime: nil, matchNumber: nil, courtNumber: nil,
            team1Score: 1, team2Score: 0, serve: "home",
            setHistory: [
                SetScore(setNumber: 1, team1Score: 21, team2Score: 18, isComplete: true),
                SetScore(setNumber: 2, team1Score: 14, team2Score: 12, isComplete: false)
            ],
            timestamp: Date(), setsToWin: 2
        )

        // Verify the data the score.json endpoint would serialize
        let currentGame = snapshot.setHistory.last
        #expect(currentGame != nil, "setHistory.last should exist for live match")
        #expect(currentGame?.team1Score == 14, "Current set score should be 14")
        #expect(currentGame?.team2Score == 12, "Current set score should be 12")

        // setsWon (team1Score/team2Score on ScoreSnapshot = sets won, not points)
        #expect(snapshot.team1Score == 1, "team1Score should be sets won (1)")
        #expect(snapshot.team2Score == 0, "team2Score should be sets won (0)")

        // totalSetsWon should agree with team1Score/team2Score
        #expect(snapshot.totalSetsWon.team1 == 1)
        #expect(snapshot.totalSetsWon.team2 == 0)

        // setNumber
        #expect(snapshot.setNumber == 2)

        // Not final
        #expect(!snapshot.isFinal)
        #expect(snapshot.hasStarted)
    }

    @Test func scoreJsonShape_waitingMatch_returnsZeroScores() async throws {
        // Simulate a .waiting court: snapshot has no real data yet
        let snapshot = ScoreSnapshot.empty(courtId: 3)

        // In .waiting, score.json guards with isLiveOrFinished = false
        // So scores should be forced to 0
        let currentGame = snapshot.setHistory.last
        #expect(currentGame == nil, "setHistory should be empty for waiting match")
        #expect(snapshot.team1Score == 0)
        #expect(snapshot.team2Score == 0)
        #expect(!snapshot.hasStarted)
    }

    @Test func scoreJsonShape_finishedMatch_setsWonMatchExpected() async throws {
        let snapshot = ScoreSnapshot(
            courtId: 1, matchId: 200,
            status: "Final", setNumber: 3,
            team1Name: "Alpha", team2Name: "Beta",
            team1Seed: nil, team2Seed: nil,
            scheduledTime: nil, matchNumber: nil, courtNumber: nil,
            team1Score: 2, team2Score: 1, serve: nil,
            setHistory: [
                SetScore(setNumber: 1, team1Score: 21, team2Score: 18, isComplete: true),
                SetScore(setNumber: 2, team1Score: 15, team2Score: 21, isComplete: true),
                SetScore(setNumber: 3, team1Score: 15, team2Score: 12, isComplete: true)
            ],
            timestamp: Date(), setsToWin: 2
        )

        #expect(snapshot.isFinal)
        #expect(snapshot.totalSetsWon.team1 == 2)
        #expect(snapshot.totalSetsWon.team2 == 1)

        // The JS isMatchFinished checks: setsWon >= setsToWin
        #expect(snapshot.totalSetsWon.team1 >= snapshot.setsToWin)
    }

    @Test func overlayJsStateLogic_intermissionWhenWaiting() async throws {
        // Simulate determineState JS logic for a waiting court
        let courtStatus = "waiting"
        let combinedScore = 0
        let setsWon1 = 0
        let setsWon2 = 0
        let matchInProgress = setsWon1 > 0 || setsWon2 > 0

        // JS: if (courtStatus === 'waiting' && combinedScore === 0 && !matchInProgress)
        //       return 'intermission'
        let shouldBeIntermission = (courtStatus == "waiting" || courtStatus == "idle")
            && combinedScore == 0 && !matchInProgress
        #expect(shouldBeIntermission, "Waiting court with 0-0 should show intermission")
    }

    @Test func overlayJsStateLogic_scoringWhenLive() async throws {
        // Simulate determineState JS logic for a live court with scoring
        let combinedScore = 14 + 12  // 26
        let setsWon1 = 1
        let setsWon2 = 0
        let setsToWin = 2
        let hasScoring = combinedScore > 0
        let matchFinished = setsWon1 >= setsToWin || setsWon2 >= setsToWin

        // JS: if (overlayState === 'intermission' && hasScoring && !matchFinished)
        //       return 'scoring'
        let shouldTransitionToScoring = hasScoring && !matchFinished
        #expect(shouldTransitionToScoring, "Live match with scores should transition to scoring")
    }

    @Test func overlayJsStateLogic_postmatchWhenFinished() async throws {
        let setsWon1 = 2
        let setsToWin = 2
        let matchFinished = setsWon1 >= setsToWin
        #expect(matchFinished, "Team with 2 sets won in best-of-3 should be finished")
    }

    @Test func setHistory_displayStrings_matchJsExpectation() async throws {
        let history = [
            SetScore(setNumber: 1, team1Score: 21, team2Score: 18, isComplete: true),
            SetScore(setNumber: 2, team1Score: 15, team2Score: 21, isComplete: true)
        ]
        let displayStrings = history.map { $0.displayString }
        #expect(displayStrings == ["21-18", "15-21"])
    }

    @Test func courtCurrentMatch_providesTeamNames() async throws {
        var court = Court.create(id: 1)
        let match = MatchItem(
            apiURL: URL(string: "https://example.com/vmix")!,
            label: "5",
            team1Name: "Smith / Jones",
            team2Name: "Brown / Davis"
        )
        court.queue = [match]
        court.activeIndex = 0

        // score.json uses currentMatch team names as fallback when snapshot has none
        #expect(court.currentMatch?.team1Name == "Smith / Jones")
        #expect(court.currentMatch?.team2Name == "Brown / Davis")
    }

    @Test func singleSetMatch_isMatchFinished_correctly() async throws {
        // setsToWin = 1 means a single-set match
        let snapshot = ScoreSnapshot(
            courtId: 1, matchId: nil,
            status: "In Progress", setNumber: 1,
            team1Name: "A", team2Name: "B",
            team1Seed: nil, team2Seed: nil,
            scheduledTime: nil, matchNumber: nil, courtNumber: nil,
            team1Score: 1, team2Score: 0, serve: nil,
            setHistory: [
                SetScore(setNumber: 1, team1Score: 28, team2Score: 22, isComplete: true)
            ],
            timestamp: Date(), setsToWin: 1
        )

        // JS: setsWon1 >= setsToWin
        #expect(snapshot.totalSetsWon.team1 >= snapshot.setsToWin)
        #expect(snapshot.isFinal)
    }
}

// MARK: - Set 3 Tiebreak Tests

struct Set3TiebreakTests {

    @Test func set3_defaultTarget15_isComplete() async throws {
        // Standard best-of-3 with 21-point sets: set 3 target is min(21, 15) = 15
        let snapshot = makeSnapshot(
            status: "Final",
            setHistory: [
                SetScore(setNumber: 1, team1Score: 21, team2Score: 18, isComplete: true),
                SetScore(setNumber: 2, team1Score: 19, team2Score: 21, isComplete: true),
                SetScore(setNumber: 3, team1Score: 15, team2Score: 10, isComplete: true)
            ]
        )
        #expect(snapshot.totalSetsWon.team1 == 2)
        #expect(snapshot.totalSetsWon.team2 == 1)
        #expect(snapshot.isFinal)
    }

    @Test func set3_lowerTarget11_isComplete() async throws {
        // Training format: sets to 11, set 3 target is min(11, 15) = 11
        let snapshot = makeSnapshot(
            status: "Final",
            setHistory: [
                SetScore(setNumber: 1, team1Score: 11, team2Score: 8, isComplete: true),
                SetScore(setNumber: 2, team1Score: 9, team2Score: 11, isComplete: true),
                SetScore(setNumber: 3, team1Score: 11, team2Score: 7, isComplete: true)
            ]
        )
        #expect(snapshot.totalSetsWon.team1 == 2)
        #expect(snapshot.totalSetsWon.team2 == 1)
        #expect(snapshot.isFinal)
    }

    @Test func set3_withPointCap_isComplete() async throws {
        // Best-of-3 to 21 with cap at 23, set 3 to 15 with cap at 23
        let snapshot = makeSnapshot(
            status: "Final",
            setHistory: [
                SetScore(setNumber: 1, team1Score: 21, team2Score: 15, isComplete: true),
                SetScore(setNumber: 2, team1Score: 18, team2Score: 21, isComplete: true),
                SetScore(setNumber: 3, team1Score: 16, team2Score: 14, isComplete: true)
            ]
        )
        #expect(snapshot.totalSetsWon.team1 == 2)
        #expect(snapshot.totalSetsWon.team2 == 1)
    }
}

// MARK: - Hydrate Parsing Tests

@MainActor
struct HydrateParsingTests {

    @Test func extractHydrateMatches_readsDayScopedBracketAndPoolMatches() async throws {
        let matches = AppViewModel.extractHydrateMatches(from: makeDayScopedHydrateJSON())
        let matchIds = matches.compactMap { $0["id"] as? Int }

        #expect(matchIds == [101, 201])
    }

    @Test func buildGameIdLookup_readsDayScopedGames() async throws {
        let lookup = AppViewModel.buildGameIdLookup(from: makeDayScopedHydrateJSON())

        #expect(lookup["101"] == [1001, 1002])
        #expect(lookup["201"] == [2001])
    }

    @Test func buildTeamLookup_resolvesNestedTeamIdsFromDayScopedHydrate() async throws {
        let lookup = AppViewModel.buildTeamLookup(from: makeDayScopedHydrateJSON())

        #expect(lookup["101"]?.team1 == "Alice Smith / Beth Jones")
        #expect(lookup["101"]?.team2 == "Cara Diaz / Dana Reed")
        #expect(lookup["201"]?.team1 == "Eva Long / Finn West")
        #expect(lookup["201"]?.team2 == "Gina Shaw / Hale Young")
    }

    @Test func extractHydrateMatches_keepsLegacyTopLevelFallback() async throws {
        let matches = AppViewModel.extractHydrateMatches(from: makeLegacyHydrateJSON())
        let matchIds = matches.compactMap { $0["id"] as? Int }

        #expect(matchIds == [301, 401])
    }
}

@MainActor
struct QueueAdvanceDecisionTests {

    @Test func shouldHoldPostMatch_isTrue_forObservedLiveFinal() async throws {
        let shouldHold = AppViewModel.shouldHoldPostMatch(
            matchConcluded: true,
            observedActiveScoring: true,
            hasScoreData: true,
            isFinalStatus: true,
            previousStatus: .live
        )

        #expect(shouldHold)
    }

    @Test func shouldHoldPostMatch_isFalse_forSyntheticBacklogWithoutEvidence() async throws {
        let shouldHold = AppViewModel.shouldHoldPostMatch(
            matchConcluded: true,
            observedActiveScoring: false,
            hasScoreData: false,
            isFinalStatus: false,
            previousStatus: .waiting
        )

        #expect(!shouldHold)
    }

    @Test func shouldAdvanceAfterConclusion_advancesStaleMatchImmediately() async throws {
        let shouldAdvance = AppViewModel.shouldAdvanceAfterConclusion(
            matchConcluded: false,
            isStale: true,
            holdExpired: false,
            shouldHoldPostMatch: true,
            nextMatchHasStarted: false
        )

        #expect(shouldAdvance)
    }

    @Test func shouldAdvanceAfterConclusion_holdsRecentFinalUntilNextMatchStarts() async throws {
        let shouldAdvance = AppViewModel.shouldAdvanceAfterConclusion(
            matchConcluded: true,
            isStale: false,
            holdExpired: false,
            shouldHoldPostMatch: true,
            nextMatchHasStarted: false
        )

        #expect(!shouldAdvance)
    }

    @Test func shouldAdvanceAfterConclusion_advancesWhenHoldExpires() async throws {
        let shouldAdvance = AppViewModel.shouldAdvanceAfterConclusion(
            matchConcluded: true,
            isStale: false,
            holdExpired: true,
            shouldHoldPostMatch: true,
            nextMatchHasStarted: false
        )

        #expect(shouldAdvance)
    }

    @Test func shouldAdvanceAfterConclusion_advancesBacklogFinalWhenNoHoldNeeded() async throws {
        let shouldAdvance = AppViewModel.shouldAdvanceAfterConclusion(
            matchConcluded: true,
            isStale: false,
            holdExpired: false,
            shouldHoldPostMatch: false,
            nextMatchHasStarted: false
        )

        #expect(shouldAdvance)
    }

    @Test func shouldAdvanceAfterConclusion_advancesHeldFinalWhenNextMatchAlreadyStarted() async throws {
        let shouldAdvance = AppViewModel.shouldAdvanceAfterConclusion(
            matchConcluded: true,
            isStale: false,
            holdExpired: false,
            shouldHoldPostMatch: true,
            nextMatchHasStarted: true
        )

        #expect(shouldAdvance)
    }
}

@MainActor
struct QueueMergeTests {

    @Test func mergeQueue_updatesExistingMetadataWithoutResettingQueuePosition() async throws {
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel()
        defer { cleanup() }

        let existingMatch = makeMatchItem(
            url: "https://example.com/match/original",
            team1: "Alice Smith / Beth Jones",
            team2: "Cara Diaz / Dana Reed",
            matchNumber: "7",
            courtNumber: "Ct 1",
            scheduledTime: "8:00AM",
            setsToWin: 1,
            pointCap: 21,
            gameIds: [111]
        )
        let secondMatch = makeMatchItem(
            url: "https://example.com/match/second",
            team1: "Eva Long / Finn West",
            team2: "Gina Shaw / Hale Young",
            matchNumber: "8"
        )

        viewModel.replaceQueue(1, with: [existingMatch, secondMatch], startIndex: 1)

        let updatedExisting = makeMatchItem(
            url: "https://example.com/match/live",
            team1: existingMatch.team1Name,
            team2: existingMatch.team2Name,
            matchNumber: existingMatch.matchNumber,
            courtNumber: "Center Court",
            scheduledTime: "8:30AM",
            setsToWin: 2,
            pointCap: 23,
            gameIds: [222, 333]
        )
        let newAppendedMatch = makeMatchItem(
            url: "https://example.com/match/new",
            team1: "Ivy Cole / June Hart",
            team2: "Kira Snow / Lane Park",
            matchNumber: "9"
        )

        viewModel.mergeQueue(1, with: [updatedExisting, newAppendedMatch])

        let court = try #require(viewModel.court(for: 1))
        #expect(court.activeIndex == 1)
        #expect(court.queue.count == 3)
        #expect(court.queue[0].apiURL == updatedExisting.apiURL)
        #expect(court.queue[0].courtNumber == "Center Court")
        #expect(court.queue[0].scheduledTime == "8:30AM")
        #expect(court.queue[0].setsToWin == 2)
        #expect(court.queue[0].pointCap == 23)
        #expect(court.queue[0].gameIds == [222, 333])
        #expect(court.queue[1].matchNumber == "8")
        #expect(court.queue[2].matchNumber == "9")
    }

    @Test func mergeQueue_usesMatchNumberToKeepRematchesDistinct() async throws {
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel()
        defer { cleanup() }

        let original = makeMatchItem(
            url: "https://example.com/match/semis",
            team1: "Alice Smith / Beth Jones",
            team2: "Cara Diaz / Dana Reed",
            matchNumber: "12"
        )
        let rematch = makeMatchItem(
            url: "https://example.com/match/finals",
            team1: original.team1Name,
            team2: original.team2Name,
            matchNumber: "18"
        )

        viewModel.replaceQueue(1, with: [original])
        viewModel.mergeQueue(1, with: [rematch])

        let court = try #require(viewModel.court(for: 1))
        #expect(court.queue.count == 2)
        #expect(court.queue.map(\.matchNumber) == ["12", "18"])
        #expect(court.queue[0].apiURL == original.apiURL)
        #expect(court.queue[1].apiURL == rematch.apiURL)
    }

    @Test func saveConfigurationNow_writesCourtsIntoInjectedConfigStoreDirectory() async throws {
        let (viewModel, configStore, cleanup) = makeIsolatedAppViewModel()
        defer { cleanup() }

        let queuedMatch = makeMatchItem(
            url: "https://example.com/match/persisted",
            team1: "Alice Smith / Beth Jones",
            team2: "Cara Diaz / Dana Reed",
            matchNumber: "5"
        )

        viewModel.replaceQueue(1, with: [queuedMatch])

        let data = try Data(contentsOf: configStore.courtsConfigURL)
        let savedCourts = try JSONDecoder().decode([Court].self, from: data)
        let savedCourt = try #require(savedCourts.first(where: { $0.id == 1 }))

        #expect(savedCourt.queue.count == 1)
        #expect(savedCourt.queue[0].apiURL == queuedMatch.apiURL)
        #expect(savedCourt.queue[0].matchNumber == "5")
    }

    @Test func replaceQueue_normalizesLegacyPoolMatchesWithoutExplicitFormatText() async throws {
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel()
        defer { cleanup() }

        let legacyPoolMatch = MatchItem(
            apiURL: URL(string: "https://example.com/vmix?court=7&bracket=false")!,
            team1Name: "Alice Smith / Beth Jones",
            team2Name: "Cara Diaz / Dana Reed",
            matchNumber: "14"
        )

        viewModel.replaceQueue(1, with: [legacyPoolMatch])

        let court = try #require(viewModel.court(for: 1))
        let normalized = try #require(court.queue.first)
        #expect(normalized.setsToWin == 1)
        #expect(normalized.pointsPerSet == 21)
        #expect(normalized.pointCap == 23)
    }

    @Test func replaceQueue_preservesExplicitFormatsForBracketAndPoolMatches() async throws {
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel()
        defer { cleanup() }

        let bracketMatch = MatchItem(
            apiURL: URL(string: "https://example.com/vmix?court=7&bracket=true")!,
            team1Name: "Alice Smith / Beth Jones",
            team2Name: "Cara Diaz / Dana Reed",
            matchNumber: "21"
        )
        let explicitPoolMatch = MatchItem(
            apiURL: URL(string: "https://example.com/vmix?court=7&bracket=false")!,
            team1Name: "Eva Long / Finn West",
            team2Name: "Gina Shaw / Hale Young",
            matchNumber: "22",
            setsToWin: 1,
            pointsPerSet: 25,
            pointCap: 27,
            formatText: "1 game to 25, cap 27"
        )

        viewModel.replaceQueue(1, with: [bracketMatch, explicitPoolMatch])

        let court = try #require(viewModel.court(for: 1))
        #expect(court.queue[0].setsToWin == nil)
        #expect(court.queue[0].pointsPerSet == nil)
        #expect(court.queue[0].pointCap == nil)
        #expect(court.queue[1].formatText == "1 game to 25, cap 27")
        #expect(court.queue[1].setsToWin == 1)
        #expect(court.queue[1].pointsPerSet == 25)
        #expect(court.queue[1].pointCap == 27)
    }
}

@MainActor
@Suite(.serialized)
struct QueueEditorSaveStateTests {

    @Test func replaceQueuePreservingState_keepsActiveIndexAndStatusWhenQueueIsUnchanged() async throws {
        let session = makeStubSession()
        let apiClient = APIClient(session: session, maxRetries: 1, retryDelay: 0)
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(apiClient: apiClient)
        defer { cleanup() }

        let firstMatch = makeMatchItem(
            url: "https://example.com/matches/queue-editor-first",
            team1: "Alice Smith / Beth Jones",
            team2: "Cara Diaz / Dana Reed",
            matchNumber: "1"
        )
        let activeMatch = makeMatchItem(
            url: "https://example.com/matches/queue-editor-active",
            team1: "Eva Long / Finn West",
            team2: "Gina Shaw / Hale Young",
            matchNumber: "2"
        )

        StubURLProtocol.registerJSON(
            makeScoreDict(status: "Pre-Match", home: 0, away: 0),
            for: activeMatch.apiURL
        )

        viewModel.replaceQueue(1, with: [firstMatch, activeMatch], startIndex: 1)
        await viewModel.runImmediatePollCycleForTesting(courtId: 1)

        viewModel.replaceQueuePreservingState(1, with: [firstMatch, activeMatch])

        let court = try #require(viewModel.court(for: 1))
        #expect(court.activeIndex == 1)
        #expect(court.status == .waiting)
        #expect(court.currentMatch?.id == activeMatch.id)
        #expect(court.lastSnapshot?.status == "Pre-Match")
    }

    @Test func replaceQueuePreservingState_tracksActiveMatchAcrossReorder() async throws {
        let session = makeStubSession()
        let apiClient = APIClient(session: session, maxRetries: 1, retryDelay: 0)
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(apiClient: apiClient)
        defer { cleanup() }

        let firstMatch = makeMatchItem(
            url: "https://example.com/matches/reorder-first",
            team1: "Alice Smith / Beth Jones",
            team2: "Cara Diaz / Dana Reed",
            matchNumber: "1"
        )
        let activeMatch = makeMatchItem(
            url: "https://example.com/matches/reorder-active",
            team1: "Eva Long / Finn West",
            team2: "Gina Shaw / Hale Young",
            matchNumber: "2"
        )
        let thirdMatch = makeMatchItem(
            url: "https://example.com/matches/reorder-third",
            team1: "Ivy North / June South",
            team2: "Kirk East / Lane West",
            matchNumber: "3"
        )

        StubURLProtocol.registerJSON(
            makeScoreDict(status: "Pre-Match", home: 0, away: 0),
            for: activeMatch.apiURL
        )

        viewModel.replaceQueue(1, with: [firstMatch, activeMatch, thirdMatch], startIndex: 1)
        await viewModel.runImmediatePollCycleForTesting(courtId: 1)

        viewModel.replaceQueuePreservingState(1, with: [activeMatch, firstMatch, thirdMatch])

        let court = try #require(viewModel.court(for: 1))
        #expect(court.activeIndex == 0)
        #expect(court.status == .waiting)
        #expect(court.currentMatch?.id == activeMatch.id)
        #expect(court.lastSnapshot?.status == "Pre-Match")
    }
}

@MainActor
@Suite(.serialized)
struct ClearAllQueuesTests {

    @Test func clearAllQueues_resetsTransientRuntimeStateAcrossCourts() async throws {
        let session = makeStubSession()
        let apiClient = APIClient(session: session, maxRetries: 1, retryDelay: 0)
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(apiClient: apiClient)
        defer { cleanup() }

        let erroredMatch = makeMatchItem(
            url: "https://example.com/matches/clear-all-error",
            team1: "Alice Smith / Beth Jones",
            team2: "Cara Diaz / Dana Reed",
            matchNumber: "1"
        )
        let finishedMatch = makeMatchItem(
            url: "https://example.com/matches/clear-all-finished",
            team1: "Eva Long / Finn West",
            team2: "Gina Shaw / Hale Young",
            matchNumber: "2",
            setsToWin: 1,
            pointCap: 23
        )

        StubURLProtocol.registerJSON(
            makeScoreDict(status: "Final", home: 21, away: 18),
            for: finishedMatch.apiURL
        )

        viewModel.replaceQueue(1, with: [erroredMatch])
        viewModel.replaceQueue(2, with: [finishedMatch])

        await viewModel.runImmediatePollCycleForTesting(courtId: 1)
        await viewModel.runImmediatePollCycleForTesting(courtId: 2)

        let beforeErrored = try #require(viewModel.court(for: 1))
        let beforeFinished = try #require(viewModel.court(for: 2))
        #expect(beforeErrored.errorMessage != nil)
        #expect(beforeErrored.lastPollTime != nil)
        #expect(beforeFinished.finishedAt != nil)
        #expect(beforeFinished.lastSnapshot?.status == "Final")
        #expect(beforeFinished.lastPollTime != nil)

        viewModel.clearAllQueues()

        for courtId in [1, 2] {
            let court = try #require(viewModel.court(for: courtId))
            #expect(court.queue.isEmpty)
            #expect(court.activeIndex == nil)
            #expect(court.status == .idle)
            #expect(court.lastSnapshot == nil)
            #expect(court.liveSince == nil)
            #expect(court.finishedAt == nil)
            #expect(court.lastPollTime == nil)
            #expect(court.errorMessage == nil)
        }
    }
}

@MainActor
@Suite(.serialized)
struct QueuePollingEdgeCaseTests {

    @Test func runImmediatePollCycle_switchesToLaterLiveMatchWhenCurrentMatchHasNotStarted() async throws {
        let session = makeStubSession()
        let apiClient = APIClient(session: session, maxRetries: 1, retryDelay: 0)
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(apiClient: apiClient)
        defer { cleanup() }

        let firstMatch = makeMatchItem(
            url: "https://example.com/matches/queue-1",
            team1: "Alice Smith / Beth Jones",
            team2: "Cara Diaz / Dana Reed",
            matchNumber: "1",
            setsToWin: 1,
            pointCap: 23
        )
        let secondMatch = makeMatchItem(
            url: "https://example.com/matches/queue-2",
            team1: "Eva Long / Finn West",
            team2: "Gina Shaw / Hale Young",
            matchNumber: "2",
            setsToWin: 1,
            pointCap: 23
        )

        StubURLProtocol.registerJSON(
            makeScoreDict(status: "Pre-Match", home: 0, away: 0),
            for: firstMatch.apiURL
        )
        StubURLProtocol.registerJSON(
            makeScoreDict(status: "In Progress", home: 8, away: 7),
            for: secondMatch.apiURL
        )

        viewModel.replaceQueue(1, with: [firstMatch, secondMatch], startIndex: 0)
        await viewModel.runImmediatePollCycleForTesting(courtId: 1)

        let court = try #require(viewModel.court(for: 1))
        #expect(court.activeIndex == 1)
        #expect(court.status == .waiting)
        #expect(court.lastSnapshot == nil)
    }

    @Test func runImmediatePollCycle_keepsCurrentMatchWhenItIsAlreadyLive() async throws {
        let session = makeStubSession()
        let apiClient = APIClient(session: session, maxRetries: 1, retryDelay: 0)
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(apiClient: apiClient)
        defer { cleanup() }

        let firstMatch = makeMatchItem(
            url: "https://example.com/matches/live-current",
            team1: "Alice Smith / Beth Jones",
            team2: "Cara Diaz / Dana Reed",
            matchNumber: "1",
            setsToWin: 1,
            pointCap: 23
        )
        let secondMatch = makeMatchItem(
            url: "https://example.com/matches/live-later",
            team1: "Eva Long / Finn West",
            team2: "Gina Shaw / Hale Young",
            matchNumber: "2",
            setsToWin: 1,
            pointCap: 23
        )

        StubURLProtocol.registerJSON(
            makeScoreDict(status: "In Progress", home: 8, away: 7),
            for: firstMatch.apiURL
        )
        StubURLProtocol.registerJSON(
            makeScoreDict(status: "In Progress", home: 10, away: 9),
            for: secondMatch.apiURL
        )

        viewModel.replaceQueue(1, with: [firstMatch, secondMatch], startIndex: 0)
        await viewModel.runImmediatePollCycleForTesting(courtId: 1)

        let court = try #require(viewModel.court(for: 1))
        #expect(court.activeIndex == 0)
        #expect(court.status == .live)
        let snapshot = try #require(court.lastSnapshot)
        #expect(snapshot.status == "In Progress")
        #expect(snapshot.setHistory.last?.team1Score == 8)
        #expect(snapshot.setHistory.last?.team2Score == 7)
    }

    @Test func runImmediatePollCycle_skipsBacklogOfCompletedMatchesBeforePollingNextPlayableMatch() async throws {
        let session = makeStubSession()
        let apiClient = APIClient(session: session, maxRetries: 1, retryDelay: 0)
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(apiClient: apiClient)
        defer { cleanup() }

        let finishedMatchOne = makeMatchItem(
            url: "https://example.com/matches/finished-1",
            team1: "Alice Smith / Beth Jones",
            team2: "Cara Diaz / Dana Reed",
            matchNumber: "1",
            setsToWin: 1,
            pointCap: 23
        )
        let finishedMatchTwo = makeMatchItem(
            url: "https://example.com/matches/finished-2",
            team1: "Eva Long / Finn West",
            team2: "Gina Shaw / Hale Young",
            matchNumber: "2",
            setsToWin: 1,
            pointCap: 23
        )
        let playableMatch = makeMatchItem(
            url: "https://example.com/matches/playable-3",
            team1: "Ivy Cole / June Hart",
            team2: "Kira Snow / Lane Park",
            matchNumber: "3",
            setsToWin: 1,
            pointCap: 23
        )

        StubURLProtocol.registerJSON(
            makeScoreDict(status: "Final", home: 21, away: 17),
            for: finishedMatchOne.apiURL
        )
        StubURLProtocol.registerJSON(
            makeScoreDict(status: "Final", home: 21, away: 19),
            for: finishedMatchTwo.apiURL
        )
        StubURLProtocol.registerJSON(
            makeScoreDict(status: "Pre-Match", home: 0, away: 0),
            for: playableMatch.apiURL
        )

        viewModel.replaceQueue(1, with: [finishedMatchOne, finishedMatchTwo, playableMatch], startIndex: 0)
        await viewModel.runImmediatePollCycleForTesting(courtId: 1)

        let court = try #require(viewModel.court(for: 1))
        #expect(court.activeIndex == 2)
        #expect(court.status == .waiting)
        let snapshot = try #require(court.lastSnapshot)
        #expect(snapshot.status == "Pre-Match")
        #expect(snapshot.matchNumber == playableMatch.matchNumber)
    }

    @Test func runImmediatePollCycle_doesNotAdvancePlayAllPoolMatchAfterOnlyOneCompletedSet() async throws {
        let session = makeStubSession()
        let apiClient = APIClient(session: session, maxRetries: 1, retryDelay: 0)
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(apiClient: apiClient)
        defer { cleanup() }

        let currentMatch = MatchItem(
            apiURL: URL(string: "https://example.com/matches/pool-play-all-current")!,
            team1Name: "William Mota / Derek Strause",
            team2Name: "Nathan Hicks / Reid Malone",
            team1Seed: "1",
            team2Seed: "3",
            matchType: "Pool Play",
            typeDetail: "Pool 1",
            scheduledTime: "9:00AM",
            startDate: "Fri",
            matchNumber: "1",
            courtNumber: "1",
            setsToWin: 1,
            setsToPlay: 2,
            pointsPerSet: 21,
            pointCap: 23,
            formatText: "Best of 2, all sets to 21 with a 23 point cap"
        )
        let nextMatch = MatchItem(
            apiURL: URL(string: "https://example.com/matches/pool-play-all-next")!,
            team1Name: "Marvin Pacheco / Derek Toliver",
            team2Name: "George Black / Daniel Wenger",
            team1Seed: "2",
            team2Seed: "4",
            matchType: "Pool Play",
            typeDetail: "Pool 1",
            scheduledTime: "9:40AM",
            startDate: "Fri",
            matchNumber: "2",
            courtNumber: "1",
            setsToWin: 1,
            setsToPlay: 2,
            pointsPerSet: 21,
            pointCap: 23,
            formatText: "Best of 2, all sets to 21 with a 23 point cap"
        )

        StubURLProtocol.registerData(
            makeVMixArrayData(
                team1Name: currentMatch.team1Name ?? "Team A",
                team2Name: currentMatch.team2Name ?? "Team B",
                game1: (18, 21),
                game2: (0, 0)
            ),
            for: currentMatch.apiURL
        )
        StubURLProtocol.registerJSON(
            makeScoreDict(status: "Pre-Match", home: 0, away: 0),
            for: nextMatch.apiURL
        )

        viewModel.replaceQueue(1, with: [currentMatch, nextMatch], startIndex: 0)
        await viewModel.runImmediatePollCycleForTesting(courtId: 1)

        let court = try #require(viewModel.court(for: 1))
        #expect(court.activeIndex == 0)
        #expect(court.status == .live)
        let snapshot = try #require(court.lastSnapshot)
        #expect(snapshot.status == "In Progress")
        #expect(snapshot.setHistory.count == 1)
        let firstSet = try #require(snapshot.setHistory.first)
        #expect(firstSet == SetScore(setNumber: 1, team1Score: 18, team2Score: 21, isComplete: true))
    }

    @Test func runImmediatePollCycle_advancesPlayAllPoolMatchAfterRequiredSetsComplete() async throws {
        let session = makeStubSession()
        let apiClient = APIClient(session: session, maxRetries: 1, retryDelay: 0)
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(apiClient: apiClient)
        defer { cleanup() }

        let currentMatch = MatchItem(
            apiURL: URL(string: "https://example.com/matches/pool-play-all-finished")!,
            team1Name: "William Mota / Derek Strause",
            team2Name: "Nathan Hicks / Reid Malone",
            team1Seed: "1",
            team2Seed: "3",
            matchType: "Pool Play",
            typeDetail: "Pool 1",
            scheduledTime: "9:00AM",
            startDate: "Fri",
            matchNumber: "1",
            courtNumber: "1",
            setsToWin: 1,
            setsToPlay: 2,
            pointsPerSet: 21,
            pointCap: 23,
            formatText: "Best of 2, all sets to 21 with a 23 point cap"
        )
        let nextMatch = MatchItem(
            apiURL: URL(string: "https://example.com/matches/pool-play-all-finished-next")!,
            team1Name: "Marvin Pacheco / Derek Toliver",
            team2Name: "George Black / Daniel Wenger",
            team1Seed: "2",
            team2Seed: "4",
            matchType: "Pool Play",
            typeDetail: "Pool 1",
            scheduledTime: "9:40AM",
            startDate: "Fri",
            matchNumber: "2",
            courtNumber: "1",
            setsToWin: 1,
            setsToPlay: 2,
            pointsPerSet: 21,
            pointCap: 23,
            formatText: "Best of 2, all sets to 21 with a 23 point cap"
        )

        StubURLProtocol.registerData(
            makeVMixArrayData(
                team1Name: currentMatch.team1Name ?? "Team A",
                team2Name: currentMatch.team2Name ?? "Team B",
                game1: (18, 21),
                game2: (21, 19)
            ),
            for: currentMatch.apiURL
        )
        StubURLProtocol.registerJSON(
            makeScoreDict(status: "Pre-Match", home: 0, away: 0),
            for: nextMatch.apiURL
        )

        viewModel.replaceQueue(1, with: [currentMatch, nextMatch], startIndex: 0)
        await viewModel.runImmediatePollCycleForTesting(courtId: 1)

        let court = try #require(viewModel.court(for: 1))
        #expect(court.activeIndex == 1)
        #expect(court.status == .waiting)
        let snapshot = try #require(court.lastSnapshot)
        #expect(snapshot.status == "Pre-Match")
    }
}

@MainActor
@Suite(.serialized)
struct QueueConclusionTimingTests {

    @Test func runImmediatePollCycle_advancesStaleLiveMatchToNextQueueItem() async throws {
        let session = makeStubSession()
        let apiClient = APIClient(session: session, maxRetries: 1, retryDelay: 0)
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(apiClient: apiClient)
        defer { cleanup() }

        let staleMatch = makeMatchItem(
            url: "https://example.com/matches/stale-live",
            team1: "Alice Smith / Beth Jones",
            team2: "Cara Diaz / Dana Reed",
            matchNumber: "1",
            setsToWin: 1,
            pointCap: 23
        )
        let nextMatch = makeMatchItem(
            url: "https://example.com/matches/stale-next",
            team1: "Eva Long / Finn West",
            team2: "Gina Shaw / Hale Young",
            matchNumber: "2",
            setsToWin: 1,
            pointCap: 23
        )

        StubURLProtocol.registerJSON(
            makeScoreDict(status: "In Progress", home: 8, away: 7),
            for: staleMatch.apiURL
        )
        StubURLProtocol.registerJSON(
            makeScoreDict(status: "Pre-Match", home: 0, away: 0),
            for: nextMatch.apiURL
        )

        viewModel.replaceQueue(1, with: [staleMatch, nextMatch], startIndex: 0)
        await viewModel.runImmediatePollCycleForTesting(courtId: 1)

        viewModel.appSettings.staleMatchTimeout = 0
        await viewModel.runImmediatePollCycleForTesting(courtId: 1)

        let court = try #require(viewModel.court(for: 1))
        #expect(court.activeIndex == 1)
        #expect(court.status == .waiting)
        #expect(court.lastSnapshot == nil)
        #expect(court.finishedAt == nil)
    }

    @Test func runImmediatePollCycle_holdsObservedFinalWhenNextMatchHasNotStarted() async throws {
        let session = makeStubSession()
        let apiClient = APIClient(session: session, maxRetries: 1, retryDelay: 0)
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(apiClient: apiClient)
        defer { cleanup() }

        let liveThenFinalMatch = makeMatchItem(
            url: "https://example.com/matches/hold-final",
            team1: "Alice Smith / Beth Jones",
            team2: "Cara Diaz / Dana Reed",
            matchNumber: "3",
            setsToWin: 1,
            pointCap: 23
        )
        let nextMatch = makeMatchItem(
            url: "https://example.com/matches/hold-next-pre",
            team1: "Eva Long / Finn West",
            team2: "Gina Shaw / Hale Young",
            matchNumber: "4",
            setsToWin: 1,
            pointCap: 23
        )

        viewModel.appSettings.holdScoreDuration = 300

        StubURLProtocol.registerJSON(
            makeScoreDict(status: "Pre-Match", home: 0, away: 0),
            for: nextMatch.apiURL
        )

        viewModel.replaceQueue(1, with: [liveThenFinalMatch, nextMatch], startIndex: 0)
        _ = await viewModel.applySnapshotForTesting(
            courtId: 1,
            snapshot: makeSnapshot(
                status: "In Progress",
                team1Score: 18,
                team2Score: 16,
                setHistory: [SetScore(setNumber: 1, team1Score: 18, team2Score: 16, isComplete: false)],
                setsToWin: 1
            )
        )
        _ = await viewModel.applySnapshotForTesting(
            courtId: 1,
            snapshot: makeSnapshot(
                status: "Final",
                team1Score: 21,
                team2Score: 16,
                setHistory: [SetScore(setNumber: 1, team1Score: 21, team2Score: 16, isComplete: true)],
                setsToWin: 1
            )
        )

        let court = try #require(viewModel.court(for: 1))
        #expect(court.activeIndex == 0)
        #expect(court.status == .finished)
        let snapshot = try #require(court.lastSnapshot)
        #expect(snapshot.status == "Final")
        #expect(court.finishedAt != nil)
    }

    @Test func runImmediatePollCycle_advancesHeldFinalWhenHoldExpires() async throws {
        let session = makeStubSession()
        let apiClient = APIClient(session: session, maxRetries: 1, retryDelay: 0)
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(apiClient: apiClient)
        defer { cleanup() }

        let liveThenFinalMatch = makeMatchItem(
            url: "https://example.com/matches/expire-final",
            team1: "Alice Smith / Beth Jones",
            team2: "Cara Diaz / Dana Reed",
            matchNumber: "5",
            setsToWin: 1,
            pointCap: 23
        )
        let nextMatch = makeMatchItem(
            url: "https://example.com/matches/expire-next-pre",
            team1: "Eva Long / Finn West",
            team2: "Gina Shaw / Hale Young",
            matchNumber: "6",
            setsToWin: 1,
            pointCap: 23
        )

        viewModel.appSettings.holdScoreDuration = 300

        StubURLProtocol.registerJSON(
            makeScoreDict(status: "Pre-Match", home: 0, away: 0),
            for: nextMatch.apiURL
        )

        viewModel.replaceQueue(1, with: [liveThenFinalMatch, nextMatch], startIndex: 0)
        _ = await viewModel.applySnapshotForTesting(
            courtId: 1,
            snapshot: makeSnapshot(
                status: "In Progress",
                team1Score: 19,
                team2Score: 18,
                setHistory: [SetScore(setNumber: 1, team1Score: 19, team2Score: 18, isComplete: false)],
                setsToWin: 1
            )
        )
        _ = await viewModel.applySnapshotForTesting(
            courtId: 1,
            snapshot: makeSnapshot(
                status: "Final",
                team1Score: 21,
                team2Score: 19,
                setHistory: [SetScore(setNumber: 1, team1Score: 21, team2Score: 19, isComplete: true)],
                setsToWin: 1
            )
        )

        viewModel.appSettings.holdScoreDuration = 0
        _ = await viewModel.applySnapshotForTesting(
            courtId: 1,
            snapshot: makeSnapshot(
                status: "Final",
                team1Score: 21,
                team2Score: 19,
                setHistory: [SetScore(setNumber: 1, team1Score: 21, team2Score: 19, isComplete: true)],
                setsToWin: 1
            )
        )

        let court = try #require(viewModel.court(for: 1))
        #expect(court.activeIndex == 1)
        #expect(court.status == .waiting)
        #expect(court.lastSnapshot == nil)
        #expect(court.finishedAt == nil)
    }

    @Test func runImmediatePollCycle_advancesHeldFinalAsSoonAsNextMatchStarts() async throws {
        let session = makeStubSession()
        let apiClient = APIClient(session: session, maxRetries: 1, retryDelay: 0)
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(apiClient: apiClient)
        defer { cleanup() }

        let liveThenFinalMatch = makeMatchItem(
            url: "https://example.com/matches/next-live-final",
            team1: "Alice Smith / Beth Jones",
            team2: "Cara Diaz / Dana Reed",
            matchNumber: "7",
            setsToWin: 1,
            pointCap: 23
        )
        let nextLiveMatch = makeMatchItem(
            url: "https://example.com/matches/next-live-match",
            team1: "Eva Long / Finn West",
            team2: "Gina Shaw / Hale Young",
            matchNumber: "8",
            setsToWin: 1,
            pointCap: 23
        )

        viewModel.appSettings.holdScoreDuration = 300

        StubURLProtocol.registerJSON(
            makeScoreDict(status: "Pre-Match", home: 0, away: 0),
            for: nextLiveMatch.apiURL
        )

        viewModel.replaceQueue(1, with: [liveThenFinalMatch, nextLiveMatch], startIndex: 0)
        _ = await viewModel.applySnapshotForTesting(
            courtId: 1,
            snapshot: makeSnapshot(
                status: "In Progress",
                team1Score: 16,
                team2Score: 14,
                setHistory: [SetScore(setNumber: 1, team1Score: 16, team2Score: 14, isComplete: false)],
                setsToWin: 1
            )
        )

        StubURLProtocol.registerJSON(
            makeScoreDict(status: "In Progress", home: 5, away: 4),
            for: nextLiveMatch.apiURL
        )
        _ = await viewModel.applySnapshotForTesting(
            courtId: 1,
            snapshot: makeSnapshot(
                status: "Final",
                team1Score: 21,
                team2Score: 14,
                setHistory: [SetScore(setNumber: 1, team1Score: 21, team2Score: 14, isComplete: true)],
                setsToWin: 1
            )
        )

        let court = try #require(viewModel.court(for: 1))
        #expect(court.activeIndex == 1)
        #expect(court.status == .waiting)
        #expect(court.lastSnapshot == nil)
        #expect(court.finishedAt == nil)
    }
}

@MainActor
@Suite(.serialized)
struct SignalRSubscriptionTests {

    @Test func signalRDidConnect_subscribesUniquePairsAcrossPollingCourtsOnly() async throws {
        let recordingClient = RecordingSignalRClient()
        let credentials = ConfigStore.VBLCredentials(username: "tester@example.com", password: "secret")
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(
            signalRCredentialsProvider: { credentials },
            signalRClientFactory: { _ in recordingClient }
        )
        defer { cleanup() }

        let sharedActiveMatch = makeMatchItem(
            url: "https://example.com/matches/signalr-shared-active",
            team1: "Alice Smith / Beth Jones",
            team2: "Cara Diaz / Dana Reed",
            matchNumber: "1",
            tournamentId: 100,
            divisionId: 10
        )
        let sharedQueuedMatch = makeMatchItem(
            url: "https://example.com/matches/signalr-shared-queued",
            team1: "Eva Long / Finn West",
            team2: "Gina Shaw / Hale Young",
            matchNumber: "2",
            tournamentId: 100,
            divisionId: 10
        )
        let secondCourtSharedMatch = makeMatchItem(
            url: "https://example.com/matches/signalr-second-shared",
            team1: "Ivy Cole / June Hart",
            team2: "Kira Snow / Lane Park",
            matchNumber: "3",
            tournamentId: 100,
            divisionId: 10
        )
        let distinctPollingMatch = makeMatchItem(
            url: "https://example.com/matches/signalr-distinct",
            team1: "Mina Vale / Nora West",
            team2: "Opal Young / Piper Zane",
            matchNumber: "4",
            tournamentId: 200,
            divisionId: 20
        )
        let idleCourtMatch = makeMatchItem(
            url: "https://example.com/matches/signalr-idle",
            team1: "Quinn Ash / Rory Blue",
            team2: "Sage Cove / Tali Dawn",
            matchNumber: "5",
            tournamentId: 300,
            divisionId: 30
        )

        viewModel.replaceQueue(1, with: [sharedActiveMatch, sharedQueuedMatch], startIndex: 0)
        viewModel.replaceQueue(2, with: [secondCourtSharedMatch, distinctPollingMatch], startIndex: 0)
        viewModel.replaceQueue(3, with: [idleCourtMatch], startIndex: 0)

        _ = await viewModel.applySnapshotForTesting(courtId: 1, snapshot: makeSnapshot(status: "Pre-Match", setsToWin: 1))
        _ = await viewModel.applySnapshotForTesting(courtId: 2, snapshot: makeSnapshot(status: "Pre-Match", setsToWin: 1))

        viewModel.setSignalREnabled(true)
        #expect(await waitUntilAsync { (await recordingClient.connectCalls()).count == 1 })

        viewModel.signalRDidConnect()
        #expect(await waitUntilAsync { (await recordingClient.subscriptions()).count == 2 })

        let subscriptions = await recordingClient.subscriptions()
        #expect(subscriptions.count == 2)
        #expect(Set(subscriptions.map { "\($0.tournamentId)-\($0.divisionId)" }) == Set(["100-10", "200-20"]))
    }

    @Test func reconnectSignalRIfNeeded_disconnectsOldClientAndResubscribesWithReplacement() async throws {
        let firstClient = RecordingSignalRClient()
        let secondClient = RecordingSignalRClient()
        let credentials = ConfigStore.VBLCredentials(username: "tester@example.com", password: "secret")
        var factoryBuildCount = 0
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(
            signalRCredentialsProvider: { credentials },
            signalRClientFactory: { _ in
                defer { factoryBuildCount += 1 }
                return factoryBuildCount == 0 ? firstClient : secondClient
            }
        )
        defer { cleanup() }

        let match = makeMatchItem(
            url: "https://example.com/matches/signalr-reconnect",
            team1: "Alice Smith / Beth Jones",
            team2: "Cara Diaz / Dana Reed",
            matchNumber: "8",
            tournamentId: 400,
            divisionId: 40
        )

        viewModel.replaceQueue(1, with: [match], startIndex: 0)
        _ = await viewModel.applySnapshotForTesting(courtId: 1, snapshot: makeSnapshot(status: "Pre-Match", setsToWin: 1))

        viewModel.setSignalREnabled(true)
        #expect(await waitUntilAsync { (await firstClient.connectCalls()).count == 1 })

        viewModel.signalRDidConnect()
        #expect(await waitUntilAsync { (await firstClient.subscriptions()).count == 1 })

        viewModel.reconnectSignalRIfNeeded()

        #expect(await waitUntilAsync { (await firstClient.disconnectCount()) == 1 })
        #expect(await waitUntilAsync { (await secondClient.connectCalls()).count == 1 })

        viewModel.signalRDidConnect()
        #expect(await waitUntilAsync { (await secondClient.subscriptions()).count == 1 })

        let firstSubscriptions = await firstClient.subscriptions()
        let secondSubscriptions = await secondClient.subscriptions()
        #expect(firstSubscriptions.map { "\($0.tournamentId)-\($0.divisionId)" } == ["400-40"])
        #expect(secondSubscriptions.map { "\($0.tournamentId)-\($0.divisionId)" } == ["400-40"])
    }
}

@MainActor
@Suite(.serialized)
struct SignalRMutationQueueTests {

    @Test func signalRDidReceiveMutation_advancesSingleSetQueueAndRemapsNextGameId() async throws {
        let session = makeStubSession()
        let apiClient = APIClient(session: session, maxRetries: 1, retryDelay: 0)
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(apiClient: apiClient)
        defer { cleanup() }

        let finishedPoolMatch = makeMatchItem(
            url: "https://example.com/matches/signalr-pool-finished",
            team1: "Alice Smith / Beth Jones",
            team2: "Cara Diaz / Dana Reed",
            matchNumber: "1",
            setsToWin: 1,
            pointCap: 23,
            gameIds: [901]
        )
        let nextPoolMatch = makeMatchItem(
            url: "https://example.com/matches/signalr-pool-next",
            team1: "Eva Long / Finn West",
            team2: "Gina Shaw / Hale Young",
            matchNumber: "2",
            setsToWin: 1,
            pointCap: 23,
            gameIds: [902]
        )

        viewModel.replaceQueue(1, with: [finishedPoolMatch, nextPoolMatch], startIndex: 0)
        _ = await viewModel.applySnapshotForTesting(courtId: 1, snapshot: makeSnapshot(status: "Pre-Match", setsToWin: 1))
        viewModel.rebuildGameIdMapForTesting()

        StubURLProtocol.registerJSON(
            makeScoreDict(status: "In Progress", home: 3, away: 2),
            for: nextPoolMatch.apiURL
        )

        viewModel.signalRDidReceiveMutation(
            name: "UPDATE_GAME",
            payload: [
                "id": 901,
                "home": 8,
                "away": 7,
                "number": 0,
                "isFinal": false
            ]
        )

        #expect(await waitUntil {
            guard let court = viewModel.court(for: 1),
                  let snapshot = court.lastSnapshot else {
                return false
            }
            return court.activeIndex == 0
                && court.status == .live
                && snapshot.status == "In Progress"
                && snapshot.setHistory.last?.team1Score == 8
                && snapshot.setHistory.last?.team2Score == 7
        })

        viewModel.signalRDidReceiveMutation(
            name: "UPDATE_GAME",
            payload: [
                "id": 901,
                "home": 21,
                "away": 16,
                "number": 0,
                "isFinal": true,
                "_winner": "home"
            ]
        )

        #expect(await waitUntil {
            guard let court = viewModel.court(for: 1) else { return false }
            return court.activeIndex == 1 && court.status == .waiting && court.lastSnapshot == nil
        })

        viewModel.signalRDidReceiveMutation(
            name: "UPDATE_GAME",
            payload: [
                "id": 902,
                "home": 5,
                "away": 4,
                "number": 0,
                "isFinal": false
            ]
        )

        #expect(await waitUntil {
            guard let court = viewModel.court(for: 1),
                  court.activeIndex == 1,
                  court.status == .live,
                  let snapshot = court.lastSnapshot else {
                return false
            }
            return snapshot.status == "In Progress"
                && snapshot.setHistory.last?.team1Score == 5
                && snapshot.setHistory.last?.team2Score == 4
        })
    }

    @Test func signalRDidReceiveMutation_waitsForBestOfThreeMatchToBeWonBeforeAdvancing() async throws {
        let session = makeStubSession()
        let apiClient = APIClient(session: session, maxRetries: 1, retryDelay: 0)
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(apiClient: apiClient)
        defer { cleanup() }

        let bracketMatch = makeMatchItem(
            url: "https://example.com/matches/signalr-bracket-current",
            team1: "Alice Smith / Beth Jones",
            team2: "Cara Diaz / Dana Reed",
            matchNumber: "10",
            setsToWin: 2,
            gameIds: [1001, 1002, 1003]
        )
        let queuedNextMatch = makeMatchItem(
            url: "https://example.com/matches/signalr-bracket-next",
            team1: "Eva Long / Finn West",
            team2: "Gina Shaw / Hale Young",
            matchNumber: "11",
            setsToWin: 2,
            gameIds: [1004, 1005, 1006]
        )

        viewModel.replaceQueue(1, with: [bracketMatch, queuedNextMatch], startIndex: 0)
        _ = await viewModel.applySnapshotForTesting(courtId: 1, snapshot: makeSnapshot(status: "Pre-Match", setsToWin: 2))
        viewModel.rebuildGameIdMapForTesting()

        StubURLProtocol.registerJSON(
            makeScoreDict(status: "In Progress", home: 6, away: 5),
            for: queuedNextMatch.apiURL
        )

        viewModel.signalRDidReceiveMutation(
            name: "UPDATE_GAME",
            payload: [
                "id": 1001,
                "home": 21,
                "away": 18,
                "number": 0,
                "isFinal": true,
                "_winner": "home"
            ]
        )

        #expect(await waitUntil {
            guard let court = viewModel.court(for: 1),
                  let snapshot = court.lastSnapshot else {
                return false
            }
            return court.activeIndex == 0
                && court.status == .live
                && snapshot.team1Score == 1
                && snapshot.team2Score == 0
                && snapshot.status == "In Progress"
        })

        viewModel.signalRDidReceiveMutation(
            name: "UPDATE_GAME",
            payload: [
                "id": 1002,
                "home": 21,
                "away": 17,
                "number": 1,
                "isFinal": true,
                "_winner": "home"
            ]
        )

        #expect(await waitUntil {
            guard let court = viewModel.court(for: 1) else { return false }
            return court.activeIndex == 1 && court.status == .waiting && court.lastSnapshot == nil
        })
    }
}

@MainActor
@Suite(.serialized)
struct CourtReassignmentTests {

    @Test func runCourtChangeForTesting_movesLiveMatchBehindTargetLiveMatchAndResetsSourceCourt() async throws {
        let session = makeStubSession()
        let apiClient = APIClient(session: session, maxRetries: 1, retryDelay: 0)
        let notificationService = RecordingNotificationService()
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(
            apiClient: apiClient,
            notificationService: notificationService
        )
        defer { cleanup() }

        let movingMatch = makeMatchItem(
            url: "https://example.com/matches/move-live",
            team1: "Alice Smith / Beth Jones",
            team2: "Cara Diaz / Dana Reed",
            matchNumber: "5",
            physicalCourt: "Court Alpha",
            scheduledTime: "9:15AM",
            setsToWin: 1,
            pointCap: 23
        )
        let sourceNextMatch = makeMatchItem(
            url: "https://example.com/matches/source-next",
            team1: "Eva Long / Finn West",
            team2: "Gina Shaw / Hale Young",
            matchNumber: "6",
            scheduledTime: "10:00AM",
            setsToWin: 1,
            pointCap: 23
        )
        let targetLiveMatch = makeMatchItem(
            url: "https://example.com/matches/target-live",
            team1: "Ivy Cole / June Hart",
            team2: "Kira Snow / Lane Park",
            matchNumber: "11",
            scheduledTime: "9:00AM",
            setsToWin: 1,
            pointCap: 23
        )
        let targetQueuedMatch = makeMatchItem(
            url: "https://example.com/matches/target-queued",
            team1: "Mina Vale / Nora West",
            team2: "Opal Young / Piper Zane",
            matchNumber: "12",
            scheduledTime: "10:30AM",
            setsToWin: 1,
            pointCap: 23
        )

        StubURLProtocol.registerJSON(
            makeScoreDict(status: "In Progress", home: 8, away: 7),
            for: movingMatch.apiURL
        )
        StubURLProtocol.registerJSON(
            makeScoreDict(status: "In Progress", home: 10, away: 9),
            for: targetLiveMatch.apiURL
        )

        viewModel.replaceQueue(1, with: [movingMatch, sourceNextMatch], startIndex: 0)
        viewModel.replaceQueue(2, with: [targetLiveMatch, targetQueuedMatch], startIndex: 0)

        await viewModel.runImmediatePollCycleForTesting(courtId: 1)
        await viewModel.runImmediatePollCycleForTesting(courtId: 2)
        await viewModel.runCourtChangeForTesting(matchId: movingMatch.id, fromCourt: 1, toCourt: 2)

        let sourceCourt = try #require(viewModel.court(for: 1))
        #expect(sourceCourt.queue.map(\.id) == [sourceNextMatch.id])
        #expect(sourceCourt.activeIndex == 0)
        #expect(sourceCourt.status == .waiting)
        #expect(sourceCourt.lastSnapshot == nil)

        let targetCourt = try #require(viewModel.court(for: 2))
        #expect(targetCourt.activeIndex == 0)
        #expect(targetCourt.status == .live)
        #expect(targetCourt.queue.count == 3)
        #expect(targetCourt.queue[0].id == targetLiveMatch.id)
        #expect(targetCourt.queue[1].id == movingMatch.id)
        #expect(targetCourt.queue[2].id == targetQueuedMatch.id)

        #expect(notificationService.courtChangeEvents.count == 1)
        let event = try #require(notificationService.courtChangeEvents.first)
        #expect(event.oldCamera == 1)
        #expect(event.newCamera == 2)
        #expect(event.isLiveMatch)
    }

    @Test func runCourtChangeForTesting_decrementsActiveIndexWhenQueuedMatchMovesOffSourceCourt() async throws {
        let notificationService = RecordingNotificationService()
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(notificationService: notificationService)
        defer { cleanup() }

        let movedMatch = makeMatchItem(
            url: "https://example.com/matches/move-queued",
            team1: "Alice Smith / Beth Jones",
            team2: "Cara Diaz / Dana Reed",
            matchNumber: "3",
            physicalCourt: "Court Beta",
            scheduledTime: "8:00AM"
        )
        let activeMatch = makeMatchItem(
            url: "https://example.com/matches/stays-active",
            team1: "Eva Long / Finn West",
            team2: "Gina Shaw / Hale Young",
            matchNumber: "4",
            scheduledTime: "9:00AM"
        )
        let laterSourceMatch = makeMatchItem(
            url: "https://example.com/matches/stays-later",
            team1: "Ivy Cole / June Hart",
            team2: "Kira Snow / Lane Park",
            matchNumber: "5",
            scheduledTime: "10:00AM"
        )
        let targetExistingEarly = makeMatchItem(
            url: "https://example.com/matches/target-early",
            team1: "Mina Vale / Nora West",
            team2: "Opal Young / Piper Zane",
            matchNumber: "9",
            scheduledTime: "9:30AM"
        )
        let targetExistingLate = makeMatchItem(
            url: "https://example.com/matches/target-late",
            team1: "Quinn Ash / Rory Blue",
            team2: "Sage Cove / Tali Dawn",
            matchNumber: "10",
            scheduledTime: "11:00AM"
        )

        viewModel.replaceQueue(1, with: [movedMatch, activeMatch, laterSourceMatch], startIndex: 1)
        viewModel.replaceQueue(2, with: [targetExistingEarly, targetExistingLate], startIndex: 0)

        await viewModel.runCourtChangeForTesting(matchId: movedMatch.id, fromCourt: 1, toCourt: 2)

        let sourceCourt = try #require(viewModel.court(for: 1))
        #expect(sourceCourt.activeIndex == 0)
        #expect(sourceCourt.queue.map(\.id) == [activeMatch.id, laterSourceMatch.id])

        let targetCourt = try #require(viewModel.court(for: 2))
        #expect(targetCourt.queue.map(\.id) == [movedMatch.id, targetExistingEarly.id, targetExistingLate.id])

        #expect(notificationService.courtChangeEvents.count == 1)
        let event = try #require(notificationService.courtChangeEvents.first)
        #expect(!event.isLiveMatch)
    }
}

@MainActor
@Suite(.serialized)
struct PollingFailureModeTests {

    @Test func runImmediatePollCycle_treatsMalformedJSONAsWaitingInsteadOfCrashing() async throws {
        let session = makeStubSession()
        let apiClient = APIClient(session: session, maxRetries: 1, retryDelay: 0)
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(apiClient: apiClient)
        defer { cleanup() }

        let match = makeMatchItem(
            url: "https://example.com/matches/malformed-json",
            team1: "Alice Smith / Beth Jones",
            team2: "Cara Diaz / Dana Reed",
            matchNumber: "1"
        )

        StubURLProtocol.registerData(Data("not-json".utf8), for: match.apiURL)

        viewModel.replaceQueue(1, with: [match], startIndex: 0)
        await viewModel.runImmediatePollCycleForTesting(courtId: 1)

        let court = try #require(viewModel.court(for: 1))
        #expect(court.activeIndex == 0)
        #expect(court.status == .waiting)
        let snapshot = try #require(court.lastSnapshot)
        #expect(snapshot.status == "Waiting")
        #expect(snapshot.team1Score == 0)
        #expect(snapshot.team2Score == 0)
    }

    @Test func runImmediatePollCycle_marksScoreOnlyPayloadAsLiveEvenWithoutStatusString() async throws {
        let session = makeStubSession()
        let apiClient = APIClient(session: session, maxRetries: 1, retryDelay: 0)
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(apiClient: apiClient)
        defer { cleanup() }

        let match = makeMatchItem(
            url: "https://example.com/matches/score-only",
            team1: "Fallback Team One",
            team2: "Fallback Team Two",
            matchNumber: "2"
        )

        StubURLProtocol.registerJSON(
            [
                "team1_text": "Live Team One",
                "team2_text": "Live Team Two",
                "score": [
                    "home": 5,
                    "away": 3
                ]
            ],
            for: match.apiURL
        )

        viewModel.replaceQueue(1, with: [match], startIndex: 0)
        await viewModel.runImmediatePollCycleForTesting(courtId: 1)

        let court = try #require(viewModel.court(for: 1))
        #expect(court.status == .live)
        let snapshot = try #require(court.lastSnapshot)
        #expect(snapshot.team1Name == "Live Team One")
        #expect(snapshot.team2Name == "Live Team Two")
        #expect(snapshot.setHistory.last?.team1Score == 5)
        #expect(snapshot.setHistory.last?.team2Score == 3)
    }

    @Test func runImmediatePollCycle_surfacesTransportFailureWithoutChangingQueuePosition() async throws {
        let session = makeStubSession()
        let apiClient = APIClient(session: session, maxRetries: 1, retryDelay: 0)
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(apiClient: apiClient)
        defer { cleanup() }

        let match = makeMatchItem(
            url: "https://example.com/matches/network-miss",
            team1: "Alice Smith / Beth Jones",
            team2: "Cara Diaz / Dana Reed",
            matchNumber: "3"
        )

        viewModel.replaceQueue(1, with: [match], startIndex: 0)
        await viewModel.runImmediatePollCycleForTesting(courtId: 1)

        let court = try #require(viewModel.court(for: 1))
        #expect(court.activeIndex == 0)
        #expect(court.status == .waiting)
        let errorMessage = try #require(court.errorMessage)
        #expect(!errorMessage.isEmpty)
        #expect(court.lastSnapshot == nil)
    }

    @Test func runImmediatePollCycle_suppressesSyntheticPoolPlaceholderHttp500() async throws {
        let session = makeStubSession()
        let apiClient = APIClient(session: session, maxRetries: 1, retryDelay: 0)
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(apiClient: apiClient)
        defer { cleanup() }

        let match = makeMatchItem(
            url: "https://example.com/matches/pool-326016-2/vmix?bracket=false",
            team1: "Placeholder Team One",
            team2: "Placeholder Team Two",
            matchNumber: "4"
        )

        StubURLProtocol.registerData(Data(), for: match.apiURL, statusCode: 500)

        viewModel.replaceQueue(1, with: [match], startIndex: 0)
        await viewModel.runImmediatePollCycleForTesting(courtId: 1)

        let court = try #require(viewModel.court(for: 1))
        #expect(court.activeIndex == 0)
        #expect(court.status == .waiting)
        #expect(court.errorMessage == nil)
        #expect(court.lastSnapshot == nil)
    }

    @Test func runImmediatePollCycle_logsSyntheticPoolPlaceholderSuppressionOnlyOnceWithinThrottleWindow() async throws {
        let session = makeStubSession()
        let apiClient = APIClient(session: session, maxRetries: 1, retryDelay: 0)
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(apiClient: apiClient)
        defer { cleanup() }

        RuntimeLogStore.shared.clear()

        let match = makeMatchItem(
            url: "https://example.com/matches/pool-326016-2/vmix?bracket=false",
            team1: "Placeholder Team One",
            team2: "Placeholder Team Two",
            matchNumber: "4"
        )

        StubURLProtocol.registerData(Data(), for: match.apiURL, statusCode: 500)

        viewModel.replaceQueue(1, with: [match], startIndex: 0)
        await viewModel.runImmediatePollCycleForTesting(courtId: 1)
        await viewModel.runImmediatePollCycleForTesting(courtId: 1)

        let logLine = "suppressed placeholder poll error for court 1: \(match.apiURL.absoluteString)"
        let recentEntries = RuntimeLogStore.shared.recentEntries(maxBytes: 16_000)
        let occurrences = recentEntries.components(separatedBy: logLine).count - 1

        #expect(occurrences == 1)
    }

    @Test func runImmediatePollCycle_logsSyntheticPoolPlaceholderSuppressionAgainAfterSuccessfulPoll() async throws {
        let session = makeStubSession()
        let apiClient = APIClient(session: session, maxRetries: 1, retryDelay: 0)
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(apiClient: apiClient)
        defer { cleanup() }

        RuntimeLogStore.shared.clear()

        let match = makeMatchItem(
            url: "https://example.com/matches/pool-326016-2/vmix?bracket=false",
            team1: "Placeholder Team One",
            team2: "Placeholder Team Two",
            matchNumber: "4"
        )

        viewModel.replaceQueue(1, with: [match], startIndex: 0)

        StubURLProtocol.registerData(Data(), for: match.apiURL, statusCode: 500)
        await viewModel.runImmediatePollCycleForTesting(courtId: 1)

        await viewModel.clearScoreCacheForTesting()
        StubURLProtocol.registerData(
            makeVMixArrayData(
                team1Name: "Placeholder Team One",
                team2Name: "Placeholder Team Two",
                game1: (0, 0)
            ),
            for: match.apiURL
        )
        await viewModel.runImmediatePollCycleForTesting(courtId: 1)

        await viewModel.clearScoreCacheForTesting()
        StubURLProtocol.registerData(Data(), for: match.apiURL, statusCode: 500)
        await viewModel.runImmediatePollCycleForTesting(courtId: 1)

        let logLine = "suppressed placeholder poll error for court 1: \(match.apiURL.absoluteString)"
        let recentEntries = RuntimeLogStore.shared.recentEntries(maxBytes: 16_000)
        let occurrences = recentEntries.components(separatedBy: logLine).count - 1

        #expect(occurrences == 2)
    }

    @Test func runImmediatePollCycle_suppressesPlaceholderQueueMetadataRefreshWarning() async throws {
        let session = makeStubSession()
        let apiClient = APIClient(session: session, maxRetries: 1, retryDelay: 0)
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(apiClient: apiClient)
        defer { cleanup() }

        RuntimeLogStore.shared.clear()

        let activeMatch = makeMatchItem(
            url: "https://example.com/matches/1217131/vmix?bracket=false",
            team1: "William Mota / Derek Strause",
            team2: "Nathan Hicks / Reid Malone",
            matchNumber: "1"
        )
        let queuedPlaceholder = makeMatchItem(
            url: "https://example.com/matches/pool-326016-2/vmix?bracket=false",
            team1: "Marvin Pacheco / Derek Toliver",
            team2: "George Black / Daniel Wenger",
            matchNumber: "2"
        )

        StubURLProtocol.registerData(
            makeVMixArrayData(
                team1Name: activeMatch.team1Name ?? "Team 1",
                team2Name: activeMatch.team2Name ?? "Team 2",
                game1: (0, 0)
            ),
            for: activeMatch.apiURL
        )
        StubURLProtocol.registerData(Data(), for: queuedPlaceholder.apiURL, statusCode: 500)

        viewModel.replaceQueue(1, with: [activeMatch, queuedPlaceholder], startIndex: 0)
        await viewModel.runImmediatePollCycleForTesting(courtId: 1)

        let recentEntries = RuntimeLogStore.shared.recentEntries(maxBytes: 16_000)
        let suppressedLine = "suppressed placeholder queue metadata refresh for court 1: \(queuedPlaceholder.apiURL.absoluteString)"

        #expect(recentEntries.contains(suppressedLine))
        #expect(!recentEntries.contains("failed to refresh queued metadata for court 1"))
    }

    @Test func runImmediatePollCycle_logsPlaceholderQueueMetadataRefreshOnlyOnceWithinThrottleWindow() async throws {
        let session = makeStubSession()
        let apiClient = APIClient(session: session, maxRetries: 1, retryDelay: 0)
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(apiClient: apiClient)
        defer { cleanup() }

        RuntimeLogStore.shared.clear()

        let activeMatch = makeMatchItem(
            url: "https://example.com/matches/1217131/vmix?bracket=false",
            team1: "William Mota / Derek Strause",
            team2: "Nathan Hicks / Reid Malone",
            matchNumber: "1"
        )
        let queuedPlaceholder = makeMatchItem(
            url: "https://example.com/matches/pool-326016-2/vmix?bracket=false",
            team1: "Marvin Pacheco / Derek Toliver",
            team2: "George Black / Daniel Wenger",
            matchNumber: "2"
        )

        StubURLProtocol.registerData(
            makeVMixArrayData(
                team1Name: activeMatch.team1Name ?? "Team 1",
                team2Name: activeMatch.team2Name ?? "Team 2",
                game1: (0, 0)
            ),
            for: activeMatch.apiURL
        )
        StubURLProtocol.registerData(Data(), for: queuedPlaceholder.apiURL, statusCode: 500)

        viewModel.replaceQueue(1, with: [activeMatch, queuedPlaceholder], startIndex: 0)
        await viewModel.runImmediatePollCycleForTesting(courtId: 1)

        await viewModel.clearScoreCacheForTesting()
        viewModel.resetQueueMetadataRefreshForTesting(courtId: 1)
        await viewModel.runImmediatePollCycleForTesting(courtId: 1)

        let logLine = "suppressed placeholder queue metadata refresh for court 1: \(queuedPlaceholder.apiURL.absoluteString)"
        let recentEntries = RuntimeLogStore.shared.recentEntries(maxBytes: 16_000)
        let occurrences = recentEntries.components(separatedBy: logLine).count - 1

        #expect(occurrences == 1)
    }

    @Test func runImmediatePollCycle_keepsRealMatchHttp500Visible() async throws {
        let session = makeStubSession()
        let apiClient = APIClient(session: session, maxRetries: 1, retryDelay: 0)
        let (viewModel, _, cleanup) = makeIsolatedAppViewModel(apiClient: apiClient)
        defer { cleanup() }

        let match = makeMatchItem(
            url: "https://example.com/matches/325750/vmix?bracket=true",
            team1: "Resolved Team One",
            team2: "Resolved Team Two",
            matchNumber: "5"
        )

        StubURLProtocol.registerData(Data(), for: match.apiURL, statusCode: 500)

        viewModel.replaceQueue(1, with: [match], startIndex: 0)
        await viewModel.runImmediatePollCycleForTesting(courtId: 1)

        let court = try #require(viewModel.court(for: 1))
        #expect(court.activeIndex == 0)
        #expect(court.status == .waiting)
        let errorMessage = try #require(court.errorMessage)
        #expect(errorMessage == "HTTP error: 500")
        #expect(court.lastSnapshot == nil)
    }
}

@MainActor
@Suite(.serialized)
struct RuntimeLogStoreTests {

    @Test func exportSnapshot_copiesCurrentRuntimeLogContents() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sourceURL = tempDirectory.appendingPathComponent("runtime.log")
        let exportURL = tempDirectory.appendingPathComponent("runtime-export.log")
        let store = RuntimeLogStore(fileURL: sourceURL)

        let sourceText = """
        2026-03-07T00:00:00.000Z [INFO] [polling] started polling for court 1
        2026-03-07T00:00:05.000Z [WARN] [polling] suppressed placeholder poll error
        """
        try sourceText.write(to: sourceURL, atomically: true, encoding: .utf8)

        try store.exportSnapshot(to: exportURL)

        let exportedText = try String(contentsOf: exportURL, encoding: .utf8)
        #expect(exportedText == sourceText)
    }

    @Test func defaultExportsDirectory_usesArchivesFolderInsideAppSupportRoot() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let exportsURL = RuntimeLogStore.defaultExportsDirectory(appSupportOverride: tempDirectory)

        #expect(exportsURL == tempDirectory.appendingPathComponent("Archives", isDirectory: true))
        #expect(FileManager.default.fileExists(atPath: exportsURL.path))
    }

    @Test func defaultFileURL_migratesLegacyRootRuntimeLogIntoLogsFolder() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let legacyURL = tempDirectory.appendingPathComponent("runtime.log")
        try "legacy runtime log\n".write(to: legacyURL, atomically: true, encoding: .utf8)

        let migratedURL = RuntimeLogStore.defaultFileURL(appSupportOverride: tempDirectory)

        #expect(migratedURL == tempDirectory.appendingPathComponent("Logs/runtime.log"))
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        let migratedText = try String(contentsOf: migratedURL, encoding: .utf8)
        #expect(migratedText == "legacy runtime log\n")
    }

    @Test func exportDiagnosticsBundle_includesManifestRuntimeLogAndAttachments() async throws {
        struct Manifest: Codable {
            let generatedAt: String
            let appVersion: String
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sourceURL = tempDirectory.appendingPathComponent("runtime.log")
        let archiveURL = tempDirectory.appendingPathComponent("diagnostics.zip")
        let extractedURL = tempDirectory.appendingPathComponent("extracted", isDirectory: true)
        let store = RuntimeLogStore(fileURL: sourceURL)

        let sourceText = "2026-03-07T00:00:00.000Z [INFO] [operator] opened settings modal\n"
        try sourceText.write(to: sourceURL, atomically: true, encoding: .utf8)

        try store.exportDiagnosticsBundle(
            to: archiveURL,
            manifest: Manifest(generatedAt: "2026-03-07T00:00:00Z", appVersion: "2.0.0"),
            attachments: [
                .init(fileName: "settings.json", data: Data("{\"serverPort\":8787}\n".utf8)),
                .init(fileName: "scanner-logs.txt", data: Data("No scanner log entries\n".utf8))
            ]
        )

        #expect(FileManager.default.fileExists(atPath: archiveURL.path))

        let listing = try shellOutput(
            executable: "/usr/bin/unzip",
            arguments: ["-Z1", archiveURL.path]
        )
        #expect(!listing.split(separator: "\n").contains(where: { $0.contains("/._") }))

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archiveURL.path, extractedURL.path]
        try unzip.run()
        unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0)

        let extractedItems = try FileManager.default.contentsOfDirectory(
            at: extractedURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let bundleDirectory = try #require(extractedItems.first)

        let exportedRuntimeLog = try String(
            contentsOf: bundleDirectory.appendingPathComponent("runtime.log"),
            encoding: .utf8
        )
        #expect(exportedRuntimeLog == sourceText)

        let manifestJSON = try String(
            contentsOf: bundleDirectory.appendingPathComponent("manifest.json"),
            encoding: .utf8
        )
        #expect(manifestJSON.contains("\"appVersion\" : \"2.0.0\""))

        let settingsJSON = try String(
            contentsOf: bundleDirectory.appendingPathComponent("settings.json"),
            encoding: .utf8
        )
        #expect(settingsJSON.contains("\"serverPort\":8787"))

        let scannerLogs = try String(
            contentsOf: bundleDirectory.appendingPathComponent("scanner-logs.txt"),
            encoding: .utf8
        )
        #expect(scannerLogs == "No scanner log entries\n")
    }

    @Test func appViewModelExportDiagnosticsBundle_includesHealthSnapshotAndCourtState() async throws {
        WebSocketHub.shared.stop()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let (viewModel, _, cleanup) = makeIsolatedAppViewModel()
        defer {
            WebSocketHub.shared.stop()
            cleanup()
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sourceURL = tempDirectory.appendingPathComponent("runtime.log")
        let archiveURL = tempDirectory.appendingPathComponent("diagnostics.zip")
        let extractedURL = tempDirectory.appendingPathComponent("extracted", isDirectory: true)
        let store = RuntimeLogStore(fileURL: sourceURL)
        try "2026-03-07T00:00:00.000Z [INFO] [operator] exported diagnostics bundle\n"
            .write(to: sourceURL, atomically: true, encoding: .utf8)

        let freePort = try reserveFreePort()
        viewModel.appSettings.serverPort = freePort
        viewModel.replaceQueue(1, with: [
            makeMatchItem(
                url: "https://example.com/match/1",
                team1: "Nathan Hicks",
                team2: "Reid Malone",
                matchNumber: "1"
            )
        ])

        await WebSocketHub.shared.start(with: viewModel, port: freePort)
        try viewModel.exportDiagnosticsBundle(to: archiveURL, runtimeLog: store)

        let listing = try shellOutput(
            executable: "/usr/bin/unzip",
            arguments: ["-Z1", archiveURL.path]
        )
        #expect(listing.contains("/health.json"))
        #expect(listing.contains("/court-state.json"))

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archiveURL.path, extractedURL.path]
        try unzip.run()
        unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0)

        let extractedItems = try FileManager.default.contentsOfDirectory(
            at: extractedURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let bundleDirectory = try #require(extractedItems.first)

        let healthData = try Data(contentsOf: bundleDirectory.appendingPathComponent("health.json"))
        let healthSnapshot = try JSONDecoder().decode(OverlayHealthSnapshot.self, from: healthData)
        #expect(healthSnapshot.port == freePort)
        #expect(healthSnapshot.courtCount == 10)

        let courtStateData = try Data(contentsOf: bundleDirectory.appendingPathComponent("court-state.json"))
        let courtSnapshots = try JSONDecoder().decode([AppViewModel.CourtDiagnosticsSnapshot].self, from: courtStateData)
        let firstCourt = try #require(courtSnapshots.first)
        #expect(firstCourt.queueCount == 1)
        #expect(firstCourt.overlayURL == "http://localhost:\(freePort)/overlay/court/1/")
    }
}

@MainActor
@Suite(.serialized)
struct OverlayServerLifecycleTests {

    @Test func startServices_surfacesConfigErrorWhenPortIsUnavailable() async throws {
        WebSocketHub.shared.stop()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let (viewModel, _, cleanup) = makeIsolatedAppViewModel()
        defer { cleanup() }

        let (lockedSocket, occupiedPort) = try reserveListeningSocket()
        defer { close(lockedSocket) }

        viewModel.appSettings.serverPort = occupiedPort
        viewModel.startServices()

        let didSurfaceError = await waitUntil {
            configErrorMessage(from: viewModel.error)?.contains("Port \(occupiedPort) unavailable") == true
        }

        #expect(didSurfaceError)
        #expect(!viewModel.serverRunning)
        let configError = try #require(configErrorMessage(from: viewModel.error))
        #expect(configError.contains("Port \(occupiedPort) unavailable"))

        viewModel.stopServices()
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    @Test func start_servesHealthEndpointOnFreePort() async throws {
        WebSocketHub.shared.stop()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let (viewModel, _, cleanup) = makeIsolatedAppViewModel()
        defer { cleanup() }

        let freePort = try reserveFreePort()
        await WebSocketHub.shared.start(with: viewModel, port: freePort)

        #expect(WebSocketHub.shared.isRunning)
        #expect(WebSocketHub.shared.startupError == nil)

        let url = try #require(URL(string: "http://127.0.0.1:\(freePort)/health"))
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)

        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["status"] as? String == "ok")
        #expect(json["serverStatus"] as? String == "running")
        #expect(json["port"] as? Int == freePort)
        #expect(json["signalRStatus"] as? String == SignalRStatus.disabled.displayLabel)
        #expect(json["signalREnabled"] as? Bool == false)
        let courts = try #require(json["courts"] as? [[String: Any]])
        #expect(courts.count == viewModel.courts.count)

        WebSocketHub.shared.stop()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(!WebSocketHub.shared.isRunning)
    }

    @Test func debugLogs_returnsRecentRuntimeEntries() async throws {
        WebSocketHub.shared.stop()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let (viewModel, _, cleanup) = makeIsolatedAppViewModel()
        defer { cleanup() }

        RuntimeLogStore.shared.clear()

        let freePort = try reserveFreePort()
        await WebSocketHub.shared.start(with: viewModel, port: freePort)

        let url = try #require(URL(string: "http://127.0.0.1:\(freePort)/debug/logs"))
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)

        let body = String(decoding: data, as: UTF8.self)
        #expect(body.contains("Path:"))
        #expect(body.contains("[overlay-server]"))
        #expect(body.contains("running at http://localhost"))

        WebSocketHub.shared.stop()
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
}

// MARK: - Test Helpers

private func makeSnapshot(
    status: String = "Pre-Match",
    setNumber: Int = 1,
    team1Score: Int = 0,
    team2Score: Int = 0,
    setHistory: [SetScore] = [],
    setsToWin: Int = 2
) -> ScoreSnapshot {
    ScoreSnapshot(
        courtId: 1,
        matchId: 1,
        status: status,
        setNumber: setNumber,
        team1Name: "Team A",
        team2Name: "Team B",
        team1Seed: nil,
        team2Seed: nil,
        scheduledTime: nil,
        matchNumber: nil,
        courtNumber: nil,
        team1Score: team1Score,
        team2Score: team2Score,
        serve: nil,
        setHistory: setHistory,
        timestamp: Date(),
        setsToWin: setsToWin
    )
}

private func makeDayScopedHydrateJSON() -> [String: Any] {
    [
        "teams": [
            makeHydrateTeam(id: 11, players: [("Alice", "Smith"), ("Beth", "Jones")]),
            makeHydrateTeam(id: 22, players: [("Cara", "Diaz"), ("Dana", "Reed")]),
            makeHydrateTeam(id: 33, players: [("Eva", "Long"), ("Finn", "West")]),
            makeHydrateTeam(id: 44, players: [("Gina", "Shaw"), ("Hale", "Young")])
        ],
        "days": [
            [
                "brackets": [
                    [
                        "matches": [
                            [
                                "id": 101,
                                "homeTeamId": 11,
                                "awayTeamId": 22,
                                "games": [
                                    ["id": 1001],
                                    ["id": 1002]
                                ]
                            ]
                        ]
                    ]
                ],
                "flights": [
                    [
                        "pools": [
                            [
                                "matches": [
                                    [
                                        "id": 201,
                                        "homeTeam": ["teamId": 33],
                                        "awayTeam": ["teamId": 44],
                                        "games": [
                                            ["id": 2001]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
    ]
}

private func makeLegacyHydrateJSON() -> [String: Any] {
    [
        "brackets": [
            [
                "matches": [
                    ["id": 301]
                ]
            ]
        ],
        "pools": [
            [
                "matches": [
                    ["id": 401]
                ]
            ]
        ]
    ]
}

@MainActor
private func makeIsolatedAppViewModel(
    apiClient: APIClient = APIClient(),
    notificationService: NotificationSending? = nil,
    signalRCredentialsProvider: (() -> ConfigStore.VBLCredentials?)? = nil,
    signalRClientFactory: ((any SignalRDelegate) -> any SignalRClienting)? = nil
) -> (AppViewModel, ConfigStore, () -> Void) {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("MultiCourtScoreTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

    let configStore = ConfigStore(appSupportOverride: tempRoot)
    let cleanup: () -> Void = {
        try? FileManager.default.removeItem(at: tempRoot)
    }
    let resolvedNotificationService = notificationService ?? RecordingNotificationService()
    let viewModel = AppViewModel(
        runtimeMode: .live,
        webSocketHub: .shared,
        configStore: configStore,
        apiClient: apiClient,
        notificationService: resolvedNotificationService,
        signalRCredentialsProvider: signalRCredentialsProvider,
        signalRClientFactory: signalRClientFactory
    )
    return (viewModel, configStore, cleanup)
}

private func makeMatchItem(
    url: String,
    team1: String?,
    team2: String?,
    matchNumber: String?,
    courtNumber: String? = nil,
    physicalCourt: String? = nil,
    scheduledTime: String? = nil,
    setsToWin: Int? = nil,
    pointCap: Int? = nil,
    gameIds: [Int]? = nil,
    tournamentId: Int? = nil,
    divisionId: Int? = nil
) -> MatchItem {
    MatchItem(
        apiURL: URL(string: url)!,
        team1Name: team1,
        team2Name: team2,
        scheduledTime: scheduledTime,
        matchNumber: matchNumber,
        courtNumber: courtNumber,
        physicalCourt: physicalCourt,
        setsToWin: setsToWin,
        pointCap: pointCap,
        divisionId: divisionId,
        tournamentId: tournamentId,
        gameIds: gameIds
    )
}

private func configErrorMessage(from error: AppError?) -> String? {
    guard case let .configError(message)? = error else { return nil }
    return message
}

private func reserveFreePort() throws -> Int {
    let (socket, port) = try reserveListeningSocket()
    close(socket)
    return port
}

private func makeStubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func makeScoreDict(
    status: String,
    home: Int,
    away: Int,
    setNumber: Int = 1
) -> [String: Any] {
    [
        "status": status,
        "setNumber": setNumber,
        "score": [
            "home": home,
            "away": away
        ]
    ]
}

private func makeVMixArrayData(
    team1Name: String,
    team2Name: String,
    game1: (Int, Int),
    game2: (Int, Int) = (0, 0),
    game3: (Int, Int) = (0, 0)
) -> Data {
    let payload: [[String: Any]] = [
        [
            "teamName": team1Name,
            "game1": game1.0,
            "game2": game2.0,
            "game3": game3.0
        ],
        [
            "teamName": team2Name,
            "game1": game1.1,
            "game2": game2.1,
            "game3": game3.1
        ]
    ]

    return (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data()
}

private func shellOutput(executable: String, arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    process.waitUntilExit()

    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

    guard process.terminationStatus == 0 else {
        let errorText = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw DiagnosticsBundleError.archiveFailed(
            errorText?.isEmpty == false ? errorText! : "Command failed: \(executable)"
        )
    }

    return String(data: outputData, encoding: .utf8) ?? ""
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var responses: [URL: (statusCode: Int, data: Data)] = [:]

    static func reset() {
        lock.lock()
        responses.removeAll()
        lock.unlock()
    }

    static func registerJSON(_ json: [String: Any], for url: URL, statusCode: Int = 200) {
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [])) ?? Data()
        lock.lock()
        responses[url] = (statusCode, data)
        lock.unlock()
    }

    static func registerData(_ data: Data, for url: URL, statusCode: Int = 200) {
        lock.lock()
        responses[url] = (statusCode, data)
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        let stub = Self.responses[url]
        Self.lock.unlock()

        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
private final class RecordingNotificationService: NotificationSending {
    private(set) var courtChangeEvents: [CourtChangeEvent] = []
    private(set) var completedMatchEvents: [(matchLabel: String, winner: String, cameraId: Int)] = []

    func sendCourtChangeAlert(_ event: CourtChangeEvent) async {
        courtChangeEvents.append(event)
    }

    func sendMatchCompleteAlert(matchLabel: String, winner: String, cameraId: Int) async {
        completedMatchEvents.append((matchLabel, winner, cameraId))
    }
}

actor RecordingSignalRClient: SignalRClienting {
    private var recordedConnectCalls: [ConfigStore.VBLCredentials] = []
    private var recordedSubscriptions: [(tournamentId: Int, divisionId: Int)] = []
    private var recordedDisconnectCount = 0

    func connect(credentials: ConfigStore.VBLCredentials) {
        recordedConnectCalls.append(credentials)
    }

    func disconnect() {
        recordedDisconnectCount += 1
    }

    func subscribeToTournament(tournamentId: Int, divisionId: Int) async {
        recordedSubscriptions.append((tournamentId, divisionId))
    }

    func connectCalls() -> [ConfigStore.VBLCredentials] {
        recordedConnectCalls
    }

    func subscriptions() -> [(tournamentId: Int, divisionId: Int)] {
        recordedSubscriptions
    }

    func disconnectCount() -> Int {
        recordedDisconnectCount
    }
}

private func reserveListeningSocket() throws -> (Int32, Int) {
    let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard socketDescriptor >= 0 else {
        throw POSIXError(.EIO)
    }

    var reuseAddr: Int32 = 1
    setsockopt(socketDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(0).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
        }
    }
    guard bindResult == 0 else {
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        close(socketDescriptor)
        throw POSIXError(code)
    }

    guard listen(socketDescriptor, SOMAXCONN) == 0 else {
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        close(socketDescriptor)
        throw POSIXError(code)
    }

    var boundAddress = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.stride)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(socketDescriptor, $0, &length)
        }
    }
    guard nameResult == 0 else {
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        close(socketDescriptor)
        throw POSIXError(code)
    }

    return (socketDescriptor, Int(UInt16(bigEndian: boundAddress.sin_port)))
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 3.0,
    pollIntervalNanoseconds: UInt64 = 50_000_000,
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
    return condition()
}

private func waitUntilAsync(
    timeout: TimeInterval = 3.0,
    pollIntervalNanoseconds: UInt64 = 50_000_000,
    condition: @escaping () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
    return await condition()
}

private func makeHydrateTeam(id: Int, players: [(String, String)]) -> [String: Any] {
    [
        "id": id,
        "players": players.map { firstName, lastName in
            [
                "firstName": firstName,
                "lastName": lastName
            ]
        }
    ]
}
