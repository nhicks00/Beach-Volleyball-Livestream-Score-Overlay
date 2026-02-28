//
//  MultiCourtScoreTests.swift
//  MultiCourtScoreTests
//
//  Comprehensive unit tests for MultiCourtScore
//

import Testing
import Foundation
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
        #expect(court.name == "Overlay 3")
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
    @Test func displayName_core1() async throws {
        #expect(CourtNaming.displayName(for: 1) == "Core 1")
    }

    @Test func displayName_mevos() async throws {
        #expect(CourtNaming.displayName(for: 2) == "Mevo 2")
        #expect(CourtNaming.displayName(for: 5) == "Mevo 5")
        #expect(CourtNaming.displayName(for: 10) == "Mevo 10")
    }

    @Test func shortName_core1() async throws {
        #expect(CourtNaming.shortName(for: 1) == "C1")
    }

    @Test func shortName_mevos() async throws {
        #expect(CourtNaming.shortName(for: 2) == "M2")
        #expect(CourtNaming.shortName(for: 10) == "M10")
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
