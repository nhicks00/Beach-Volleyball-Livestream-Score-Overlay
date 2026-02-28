//
//  MultiCourtScoreTests.swift
//  MultiCourtScoreTests
//
//  Created by Nathan Hicks on 8/24/25.
//

import Testing
import Foundation
@testable import MultiCourtScore

struct MultiCourtScoreTests {

    @Test func hasStarted_isTrue_whenStatusIsInProgress() async throws {
        let snapshot = makeSnapshot(
            status: "In Progress",
            setNumber: 1,
            team1Score: 0,
            team2Score: 0,
            setHistory: []
        )
        #expect(snapshot.hasStarted)
    }

    @Test func hasStarted_isTrue_whenScoresExistWithoutSetHistory() async throws {
        let snapshot = makeSnapshot(
            status: "Pre-Match",
            setNumber: 1,
            team1Score: 7,
            team2Score: 6,
            setHistory: []
        )
        #expect(snapshot.hasStarted)
    }

    @Test func hasStarted_isFalse_whenPreMatchAndNoScores() async throws {
        let snapshot = makeSnapshot(
            status: "Pre-Match",
            setNumber: 1,
            team1Score: 0,
            team2Score: 0,
            setHistory: []
        )
        #expect(!snapshot.hasStarted)
    }
    
    @Test func isFinal_isTrue_forSingleSetPoolMatch() async throws {
        let snapshot = makeSnapshot(
            status: "In Progress",
            setNumber: 2,
            team1Score: 1,
            team2Score: 0,
            setHistory: [
                SetScore(setNumber: 1, team1Score: 23, team2Score: 21, isComplete: true)
            ],
            setsToWin: 1
        )
        #expect(snapshot.isFinal)
    }
    
    @Test func isFinal_isFalse_forSingleSetPoolMatchInProgress() async throws {
        let snapshot = makeSnapshot(
            status: "In Progress",
            setNumber: 1,
            team1Score: 0,
            team2Score: 0,
            setHistory: [
                SetScore(setNumber: 1, team1Score: 20, team2Score: 19, isComplete: false)
            ],
            setsToWin: 1
        )
        #expect(!snapshot.isFinal)
    }

    private func makeSnapshot(
        status: String,
        setNumber: Int,
        team1Score: Int,
        team2Score: Int,
        setHistory: [SetScore],
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

}
