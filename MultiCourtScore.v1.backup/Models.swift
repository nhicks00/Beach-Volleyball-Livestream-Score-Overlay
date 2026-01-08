import Foundation

// MARK: - Core App Models

struct MatchItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var apiURL: URL
    var label: String?
    var team1Name: String?
    var team2Name: String?

    init(apiURL: URL, label: String? = nil, team1Name: String? = nil, team2Name: String? = nil) {
        self.apiURL = apiURL
        self.label = label
        self.team1Name = team1Name
        self.team2Name = team2Name
    }

    // MARK: Codable Conformance
    enum CodingKeys: String, CodingKey {
        case apiURL, label, id, team1Name, team2Name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiURL = try container.decode(URL.self, forKey: .apiURL)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        team1Name = try container.decodeIfPresent(String.self, forKey: .team1Name)
        team2Name = try container.decodeIfPresent(String.self, forKey: .team2Name)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(apiURL, forKey: .apiURL)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(team1Name, forKey: .team1Name)
        try container.encodeIfPresent(team2Name, forKey: .team2Name)
        try container.encode(id, forKey: .id)
    }
    
    var displayName: String {
        if let t1 = team1Name, let t2 = team2Name {
            return "\(t1) vs \(t2)"
        } else if let label = label {
            return label
        } else {
            return "Match"
        }
    }
}

enum CourtStatus: String, Codable {
    case idle
    case waiting
    case live
    case finished
    case error
}

struct ScoreSnapshot: Codable {
    var court: Int
    var matchId: Int?
    var status: String
    var setNumber: Int
    var team1Name: String
    var team2Name: String
    var team1Score: Int
    var team2Score: Int
    var serve: String?
    var setHistory: [SetScore] = []
}

struct SetScore: Codable {
    var setNumber: Int
    var team1Score: Int
    var team2Score: Int
    var isComplete: Bool
}

struct Court: Identifiable, Codable {
    var id: Int
    var name: String
    var queue: [MatchItem]
    var activeIndex: Int?
    var status: CourtStatus
    var lastSnapshot: ScoreSnapshot?
    var liveSince: Date? // For stopwatch functionality
}

