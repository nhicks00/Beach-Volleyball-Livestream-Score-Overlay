//
//  ChangeLogService.swift
//  MultiCourtScore
//
//  Service to track and persist metadata changes for matches
//

import Foundation

struct ChangeLogItem: Identifiable, Codable {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        return f
    }()

    var id = UUID()
    var timestamp: Date
    var courtId: Int
    var matchLabel: String       // e.g. "Match 5" (human readable)
    var teamVsTeam: String       // e.g. "Team A vs Team B"
    var fieldName: String        // e.g. "Start Time", "Court", "Team 1"
    var oldValue: String
    var newValue: String

    var displayTime: String {
        Self.timeFormatter.string(from: timestamp)
    }
}

@MainActor
class ChangeLogService: ObservableObject {
    static let shared = ChangeLogService()
    
    @Published var logs: [ChangeLogItem] = []
    
    private let maxLogs = 100
    
    func logChange(courtId: Int, match: MatchItem, field: String, old: String, new: String) {
        // Ignore whitespace-only changes
        guard old.trimmingCharacters(in: .whitespacesAndNewlines) != new.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        
        let matchLabel = match.matchNumber ?? "Next Match"
        let teamVsTeam = "\(match.team1Name ?? "TBD") vs \(match.team2Name ?? "TBD")"
        
        let item = ChangeLogItem(
            timestamp: Date(),
            courtId: courtId,
            matchLabel: matchLabel,
            teamVsTeam: teamVsTeam,
            fieldName: field,
            oldValue: old,
            newValue: new
        )
        
        logs.insert(item, at: 0)
        
        // Trim log if too long
        if logs.count > maxLogs {
            logs = Array(logs.prefix(maxLogs))
        }
        
        print("📝 Change Detected [Court \(courtId)]: \(field) changed from '\(old)' to '\(new)' for \(matchLabel)")
    }
    
    func clearLogs() {
        logs.removeAll()
    }
}
