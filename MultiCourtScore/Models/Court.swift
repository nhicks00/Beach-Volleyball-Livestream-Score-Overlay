//
//  Court.swift
//  MultiCourtScore v2
//
//  Core data models for courts et matches
//

import Foundation

// MARK: - Court Status
enum CourtStatus: String, Codable, CaseIterable {
    case idle       // No active polling, no matches or not started
    case waiting    // Polling active, waiting for match to start (score 0-0)
    case live       // Match in progress, actively polling
    case finished   // Match completed, showing final score
    case error      // Error state, polling failed
    
    var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .waiting: return "Waiting"
        case .live: return "Live"
        case .finished: return "Finished"
        case .error: return "Error"
        }
    }
    
    var isPolling: Bool {
        switch self {
        case .waiting, .live, .finished:
            return true
        case .idle, .error:
            return false
        }
    }
}

// MARK: - Match Item
struct MatchItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var apiURL: URL
    var label: String?
    var team1Name: String?
    var team2Name: String?
    var team1Seed: String?
    var team2Seed: String?
    var matchType: String?      // "Pool Play", "Bracket Play"
    var typeDetail: String?     // "Pool A", "Winners Bracket"
    var scheduledTime: String?
    var matchNumber: String?    // "Match 1", "18", etc.
    var courtNumber: String?    // Original court number from VBL
    var physicalCourt: String?  // VBL court name for tracking reassignments (e.g., "Court 1", "Stadium Court")
    // Match format fields
    var setsToWin: Int?          // 1, 2, or 3 (nil defaults to 2)
    var pointsPerSet: Int?       // Points to win a set (usually 21)
    var pointCap: Int?           // Point cap (e.g., 23), nil means win by 2
    var formatText: String?      // Raw format text from scraper
    var team1_score: Int?        // Live score
    var team2_score: Int?        // Live score
    
    init(
        apiURL: URL,
        label: String? = nil,
        team1Name: String? = nil,
        team2Name: String? = nil,
        team1Seed: String? = nil,
        team2Seed: String? = nil,
        matchType: String? = nil,
        typeDetail: String? = nil,
        scheduledTime: String? = nil,
        matchNumber: String? = nil,
        courtNumber: String? = nil,
        physicalCourt: String? = nil,
        setsToWin: Int? = nil,
        pointsPerSet: Int? = nil,
        pointCap: Int? = nil,
        formatText: String? = nil,
        team1_score: Int? = nil,
        team2_score: Int? = nil
    ) {
        self.apiURL = apiURL
        self.label = label
        self.team1Name = team1Name
        self.team2Name = team2Name
        self.team1Seed = team1Seed
        self.team2Seed = team2Seed
        self.matchType = matchType
        self.typeDetail = typeDetail
        self.scheduledTime = scheduledTime
        self.matchNumber = matchNumber
        self.courtNumber = courtNumber
        self.physicalCourt = physicalCourt
        self.setsToWin = setsToWin
        self.pointsPerSet = pointsPerSet
        self.pointCap = pointCap
        self.formatText = formatText
        self.team1_score = team1_score
        self.team2_score = team2_score
    }
    
    var displayName: String {
        if let t1 = team1Name, let t2 = team2Name, !t1.isEmpty, !t2.isEmpty {
            return "\(t1) vs \(t2)"
        } else if let label = label, !label.isEmpty {
            return label
        } else {
            return "Match"
        }
    }
    
    var shortDisplayName: String {
        if let t1 = team1Name, let t2 = team2Name, !t1.isEmpty, !t2.isEmpty {
            let short1 = t1.components(separatedBy: " ").first ?? t1
            let short2 = t2.components(separatedBy: " ").first ?? t2
            return "\(short1) v \(short2)"
        } else if let label = label, !label.isEmpty {
            return label
        } else {
            return "Match"
        }
    }
    
    // MARK: Codable Conformance
    enum CodingKeys: String, CodingKey {
        case id, apiURL, label, team1Name, team2Name, team1Seed, team2Seed
        case matchType, typeDetail, scheduledTime, matchNumber, courtNumber, physicalCourt
        case setsToWin, pointsPerSet, pointCap, formatText
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiURL = try container.decode(URL.self, forKey: .apiURL)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        team1Name = try container.decodeIfPresent(String.self, forKey: .team1Name)
        team2Name = try container.decodeIfPresent(String.self, forKey: .team2Name)
        team1Seed = try container.decodeIfPresent(String.self, forKey: .team1Seed)
        team2Seed = try container.decodeIfPresent(String.self, forKey: .team2Seed)
        matchType = try container.decodeIfPresent(String.self, forKey: .matchType)
        typeDetail = try container.decodeIfPresent(String.self, forKey: .typeDetail)
        scheduledTime = try container.decodeIfPresent(String.self, forKey: .scheduledTime)
        matchNumber = try container.decodeIfPresent(String.self, forKey: .matchNumber)
        courtNumber = try container.decodeIfPresent(String.self, forKey: .courtNumber)
        physicalCourt = try container.decodeIfPresent(String.self, forKey: .physicalCourt)
        setsToWin = try container.decodeIfPresent(Int.self, forKey: .setsToWin)
        pointsPerSet = try container.decodeIfPresent(Int.self, forKey: .pointsPerSet)
        pointCap = try container.decodeIfPresent(Int.self, forKey: .pointCap)
        formatText = try container.decodeIfPresent(String.self, forKey: .formatText)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    }
}

// MARK: - Set Score
struct SetScore: Codable, Hashable {
    var setNumber: Int
    var team1Score: Int
    var team2Score: Int
    var isComplete: Bool
    
    var displayString: String {
        return "\(team1Score)-\(team2Score)"
    }
}

// MARK: - Score Snapshot
struct ScoreSnapshot: Codable {
    var courtId: Int
    var matchId: Int?
    var status: String              // "Pre-Match", "In Progress", "Final"
    var setNumber: Int
    var team1Name: String
    var team2Name: String
    var team1Seed: String?
    var team2Seed: String?
    var team1Score: Int
    var team2Score: Int
    var serve: String?              // "home", "away", or nil
    var setHistory: [SetScore]
    var timestamp: Date
    var setsToWin: Int              // 1, 2, or 3 (defaults to 2)
    
    var isFinal: Bool {
        // First check status string from API
        if status.lowercased().contains("final") {
            return true
        }
        // Also check if enough sets have been won
        let setsWon = totalSetsWon
        return setsWon.team1 >= setsToWin || setsWon.team2 >= setsToWin
    }
    
    var hasStarted: Bool {
        // Any match with points in the current set (or later sets) has started
        if setNumber > 1 { return true }
        if let firstSet = setHistory.first {
            return firstSet.team1Score > 0 || firstSet.team2Score > 0
        }
        return false
    }
    
    var totalSetsWon: (team1: Int, team2: Int) {
        var t1 = 0, t2 = 0
        for set in setHistory where set.isComplete {
            if set.team1Score > set.team2Score { t1 += 1 }
            else { t2 += 1 }
        }
        return (t1, t2)
    }
    
    static func empty(courtId: Int) -> ScoreSnapshot {
        return ScoreSnapshot(
            courtId: courtId,
            matchId: nil,
            status: "Waiting",
            setNumber: 1,
            team1Name: "Team A",
            team2Name: "Team B",
            team1Seed: nil,
            team2Seed: nil,
            team1Score: 0,
            team2Score: 0,
            serve: nil,
            setHistory: [],
            timestamp: Date(),
            setsToWin: 2  // Default to best-of-3
        )
    }
}

// MARK: - Court
struct Court: Identifiable, Codable {
    var id: Int
    var name: String
    var queue: [MatchItem]
    var activeIndex: Int?
    var status: CourtStatus
    var lastSnapshot: ScoreSnapshot?
    var liveSince: Date?            // For stopwatch functionality
    var finishedAt: Date?           // When the current match finished (for hold timer)
    var lastPollTime: Date?
    var errorMessage: String?
    
    // MARK: Computed Properties
    
    var displayName: String {
        return CourtNaming.displayName(for: id)
    }
    
    var currentMatch: MatchItem? {
        guard let idx = activeIndex, idx >= 0, idx < queue.count else { return nil }
        return queue[idx]
    }
    
    var nextMatch: MatchItem? {
        guard let idx = activeIndex, idx + 1 < queue.count else { return nil }
        return queue[idx + 1]
    }
    
    var upcomingMatches: [MatchItem] {
        guard let idx = activeIndex else { return [] }
        let startIndex = idx + 1
        guard startIndex < queue.count else { return [] }
        return Array(queue[startIndex...].prefix(AppConfig.maxQueuePreview))
    }
    
    var remainingMatchCount: Int {
        guard let idx = activeIndex else { return queue.count }
        return max(0, queue.count - idx - 1)
    }
    
    var elapsedTime: TimeInterval? {
        guard let start = liveSince else { return nil }
        return Date().timeIntervalSince(start)
    }
    
    var elapsedTimeString: String? {
        guard let elapsed = elapsedTime else { return nil }
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    // MARK: Factory Methods
    
    static func create(id: Int, name: String? = nil) -> Court {
        return Court(
            id: id,
            name: name ?? "Overlay \(id)",
            queue: [],
            activeIndex: nil,
            status: .idle,
            lastSnapshot: nil,
            liveSince: nil,
            finishedAt: nil,
            lastPollTime: nil,
            errorMessage: nil
        )
    }
}

// MARK: - App Error
enum AppError: Error, LocalizedError {
    case networkError(String)
    case parsingError(String)
    case scraperError(String)
    case configError(String)
    case unknown(String)
    
    var errorDescription: String? {
        switch self {
        case .networkError(let msg): return "Network error: \(msg)"
        case .parsingError(let msg): return "Parsing error: \(msg)"
        case .scraperError(let msg): return "Scraper error: \(msg)"
        case .configError(let msg): return "Configuration error: \(msg)"
        case .unknown(let msg): return "Error: \(msg)"
        }
    }
}
