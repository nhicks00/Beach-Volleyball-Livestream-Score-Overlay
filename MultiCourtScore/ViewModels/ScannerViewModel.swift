//
//  ScannerViewModel.swift
//  MultiCourtScore v2
//
//  View model for VBL scanning functionality
//

import Foundation
import SwiftUI

@MainActor
class ScannerViewModel: ObservableObject {
    // MARK: - Published State
    @Published var isScanning = false
    @Published var scanProgress = ""
    @Published var scanLogs: [ScanLogEntry] = []
    @Published var scanResults: [VBLMatch] = []
    @Published var errorMessage: String?
    
    // MARK: - Scan URLs (dynamic arrays)
    @Published var bracketURLs: [String] = [""]
    @Published var poolURLs: [String] = [""]
    
    // MARK: - URL Management
    func addBracketURL() {
        bracketURLs.append("")
    }
    
    func removeBracketURL(at index: Int) {
        guard bracketURLs.count > 1, bracketURLs.indices.contains(index) else { return }
        bracketURLs.remove(at: index)
    }
    
    func addPoolURL() {
        poolURLs.append("")
    }
    
    func removePoolURL(at index: Int) {
        guard poolURLs.count > 1, poolURLs.indices.contains(index) else { return }
        poolURLs.remove(at: index)
    }
    
    // MARK: - Private State
    private var currentProcess: Process?
    
    // MARK: - Types
    
    struct ScanLogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
        let type: LogType
        
        enum LogType {
            case info, success, warning, error
            
            var icon: String {
                switch self {
                case .info: return "ℹ️"
                case .success: return "✅"
                case .warning: return "⚠️"
                case .error: return "❌"
                }
            }
            
            var color: Color {
                switch self {
                case .info: return AppColors.textSecondary
                case .success: return AppColors.success
                case .warning: return AppColors.warning
                case .error: return AppColors.error
                }
            }
        }
        
        var timeDisplay: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return formatter.string(from: timestamp)
        }
    }
    
    struct VBLMatch: Codable, Identifiable {
        let id = UUID()
        let index: Int
        let team1: String?
        let team2: String?
        let team1_seed: String?
        let team2_seed: String?
        let matchNumber: String?
        let court: String?
        let startTime: String?
        let startDate: String?  // Day of week or date (e.g., "Thu", "Friday", "1/2")
        let apiURL: String?
        let matchType: String?
        let typeDetail: String?
        // Match format fields
        let setsToWin: Int?
        let pointsPerSet: Int?
        let pointCap: Int?
        let formatText: String?
        
        var displayName: String {
            if let t1 = team1, let t2 = team2, !t1.isEmpty, !t2.isEmpty {
                return "\(t1) vs \(t2)"
            }
            return matchNumber ?? "Match \(index + 1)"
        }
        
        var courtDisplay: String { court ?? "TBD" }
        var timeDisplay: String { startTime ?? "TBD" }
        /// Combined date and time display (e.g., "Thu 8:00AM" or just "8:00AM")
        var dateTimeDisplay: String {
            if let date = startDate, let time = startTime {
                return "\(date) \(time)"
            }
            return startTime ?? startDate ?? "TBD"
        }
        var hasAPIURL: Bool { apiURL != nil && !apiURL!.isEmpty }
        
        enum CodingKeys: String, CodingKey {
            case index, team1, team2, team1_seed, team2_seed, matchNumber, court, startTime, startDate
            case apiURL = "api_url"
            case matchType = "match_type"
            case typeDetail = "type_detail"
            case setsToWin, pointsPerSet, pointCap, formatText
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            index = try container.decode(Int.self, forKey: .index)
            team1 = try container.decodeIfPresent(String.self, forKey: .team1)
            team2 = try container.decodeIfPresent(String.self, forKey: .team2)
            team1_seed = try container.decodeIfPresent(String.self, forKey: .team1_seed)
            team2_seed = try container.decodeIfPresent(String.self, forKey: .team2_seed)
            matchNumber = try container.decodeIfPresent(String.self, forKey: .matchNumber)
            court = try container.decodeIfPresent(String.self, forKey: .court)
            startTime = try container.decodeIfPresent(String.self, forKey: .startTime)
            startDate = try container.decodeIfPresent(String.self, forKey: .startDate)
            apiURL = try container.decodeIfPresent(String.self, forKey: .apiURL)
            matchType = try container.decodeIfPresent(String.self, forKey: .matchType)
            typeDetail = try container.decodeIfPresent(String.self, forKey: .typeDetail)
            setsToWin = try container.decodeIfPresent(Int.self, forKey: .setsToWin)
            pointsPerSet = try container.decodeIfPresent(Int.self, forKey: .pointsPerSet)
            pointCap = try container.decodeIfPresent(Int.self, forKey: .pointCap)
            formatText = try container.decodeIfPresent(String.self, forKey: .formatText)
        }
    }
    
    // MARK: - Computed Properties
    
    var allURLs: [String] {
        (bracketURLs + poolURLs)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    
    var canScan: Bool {
        !allURLs.isEmpty && !isScanning
    }
    
    var groupedByCourt: [String: [VBLMatch]] {
        var grouped = Dictionary(grouping: scanResults) { $0.courtDisplay }
        
        // Sort matches within each group by: time, then match number, then discovery order
        for (court, matches) in grouped {
            grouped[court] = matches.sorted { a, b in
                // Compare by time first (if both have times)
                if let timeA = a.startTime, let timeB = b.startTime {
                    let timeCompare = compareTimeStrings(timeA, timeB)
                    if timeCompare != 0 { return timeCompare < 0 }
                } else if a.startTime != nil {
                    return true  // a has time, b doesn't - a comes first
                } else if b.startTime != nil {
                    return false // b has time, a doesn't - b comes first
                }
                
                // Then compare by match number
                if let numA = a.matchNumber, let numB = b.matchNumber,
                   let intA = Int(numA), let intB = Int(numB) {
                    if intA != intB { return intA < intB }
                } else if a.matchNumber != nil {
                    return true
                } else if b.matchNumber != nil {
                    return false
                }
                
                // Finally by discovery order (index)
                return a.index < b.index
            }
        }
        
        return grouped
    }
    
    /// Compare two time strings like "8:00AM" and "11:00AM"
    private func compareTimeStrings(_ a: String, _ b: String) -> Int {
        // Parse hour and AM/PM
        let pattern = #"(\d{1,2}):(\d{2})\s*(AM|PM)"#
        guard let regexA = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let regexB = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let matchA = regexA.firstMatch(in: a, range: NSRange(a.startIndex..., in: a)),
              let matchB = regexB.firstMatch(in: b, range: NSRange(b.startIndex..., in: b)) else {
            return a.compare(b).rawValue
        }
        
        let hourA = Int(a[Range(matchA.range(at: 1), in: a)!]) ?? 0
        let hourB = Int(b[Range(matchB.range(at: 1), in: b)!]) ?? 0
        let minA = Int(a[Range(matchA.range(at: 2), in: a)!]) ?? 0
        let minB = Int(b[Range(matchB.range(at: 2), in: b)!]) ?? 0
        let ampmA = a[Range(matchA.range(at: 3), in: a)!].uppercased()
        let ampmB = b[Range(matchB.range(at: 3), in: b)!].uppercased()
        
        // Convert to 24-hour for comparison
        let hour24A = (ampmA == "PM" && hourA != 12 ? hourA + 12 : (ampmA == "AM" && hourA == 12 ? 0 : hourA))
        let hour24B = (ampmB == "PM" && hourB != 12 ? hourB + 12 : (ampmB == "AM" && hourB == 12 ? 0 : hourB))
        
        if hour24A != hour24B { return hour24A - hour24B }
        return minA - minB
    }
    
    // MARK: - Actions
    
    func startScan() {
        guard canScan else { return }
        
        isScanning = true
        scanLogs.removeAll()
        scanResults = []
        errorMessage = nil
        scanProgress = "Initializing scan..."
        
        addLog("Starting VBL scan for \(allURLs.count) URL(s)", type: .info)
        
        Task {
            await performScan()
        }
    }
    
    func cancelScan() {
        currentProcess?.terminate()
        currentProcess = nil
        isScanning = false
        scanProgress = "Scan cancelled"
        addLog("Scan cancelled by user", type: .warning)
    }
    
    func clearResults() {
        scanResults = []
        scanLogs = []
        errorMessage = nil
        scanProgress = ""
    }
    
    // MARK: - Private Methods
    
    private func performScan() async {
        let basePath = getBasePath()
        
        // Production scraper paths (current location)
        let productionVenvPython = "\(basePath)/MultiCourtScore/Scrapers/venv/bin/python3"
        let productionScriptPath = "\(basePath)/MultiCourtScore/Scrapers/vbl_scraper/cli.py"
        let productionWorkingDir = "\(basePath)/MultiCourtScore/Scrapers"
        
        // Fallback to system Python if venv doesn't exist
        let systemPython = "/usr/bin/python3"
        
        // Determine which Python to use
        let useVenv = FileManager.default.fileExists(atPath: productionVenvPython) &&
                      FileManager.default.fileExists(atPath: productionScriptPath)
        
        let pythonPath = useVenv ? productionVenvPython : systemPython
        let scriptPath = productionScriptPath
        let workingDir = productionWorkingDir
        
        addLog("Using \(useVenv ? "venv" : "system") Python", type: .info)
        addLog("Python: \(pythonPath)", type: .info)
        addLog("Script: \(scriptPath)", type: .info)
        
        for (index, url) in allURLs.enumerated() {
            scanProgress = "Scanning URL \(index + 1) of \(allURLs.count)..."
            addLog("Scanning: \(url)", type: .info)
            
            let matches = await scanSingleURL(
                url, 
                pythonPath: pythonPath, 
                scriptPath: scriptPath,
                workingDir: workingDir
            )
            
            if !matches.isEmpty {
                scanResults.append(contentsOf: matches)
                addLog("Found \(matches.count) matches from URL \(index + 1)", type: .success)
            } else {
                addLog("No matches found from URL \(index + 1)", type: .warning)
            }
            
            // Small delay between URLs
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        
        isScanning = false
        
        if scanResults.isEmpty {
            errorMessage = "No matches found in any of the \(allURLs.count) URLs"
            scanProgress = "Scan complete - no matches found"
        } else {
            scanProgress = "Found \(scanResults.count) matches total"
            addLog("Scan complete: \(scanResults.count) total matches", type: .success)
        }
    }
    
    private func scanSingleURL(_ url: String, pythonPath: String, scriptPath: String, workingDir: String) async -> [VBLMatch] {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                let errorPipe = Pipe()
                
                // Generate unique output file to avoid conflicts
                let outputFile = URL(fileURLWithPath: workingDir)
                    .appendingPathComponent("scan_results_\(UUID().uuidString.prefix(8)).json")
                
                process.executableURL = URL(fileURLWithPath: pythonPath)
                process.arguments = ["-m", "vbl_scraper.cli", url, "-o", outputFile.path]
                process.currentDirectoryURL = URL(fileURLWithPath: workingDir)
                process.standardOutput = pipe
                process.standardError = errorPipe
                
                // Add environment for Python
                var env = ProcessInfo.processInfo.environment
                env["PYTHONPATH"] = workingDir
                process.environment = env
                
                Task { @MainActor in
                    self.currentProcess = process
                }
                
                do {
                    Task { @MainActor in
                        self.addLog("Running Python process...", type: .info)
                    }
                    
                    try process.run()
                    process.waitUntilExit()
                    
                    let exitCode = process.terminationStatus
                    
                    // Read stderr for debugging
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    if !errorData.isEmpty, let errorString = String(data: errorData, encoding: .utf8) {
                        Task { @MainActor in
                            for line in errorString.split(separator: "\n").prefix(5) {
                                self.addLog("Python: \(line)", type: .warning)
                            }
                        }
                    }
                    
                    if exitCode != 0 {
                        Task { @MainActor in
                            self.addLog("Python exited with code \(exitCode)", type: .error)
                        }
                    }
                    
                    // Try to load results from output file
                    if let data = try? Data(contentsOf: outputFile),
                       let result = try? JSONDecoder().decode(ScanResultWrapper.self, from: data) {
                        // Clean up temp file
                        try? FileManager.default.removeItem(at: outputFile)
                        
                        // Handle both single result and array result formats
                        if let matches = result.matches {
                            continuation.resume(returning: matches)
                        } else if let results = result.results, let first = results.first {
                            continuation.resume(returning: first.matches)
                        } else {
                            continuation.resume(returning: [])
                        }
                    } else {
                        Task { @MainActor in
                            self.addLog("Could not read results file", type: .error)
                        }
                        continuation.resume(returning: [])
                    }
                } catch {
                    Task { @MainActor in
                        self.addLog("Scan error: \(error.localizedDescription)", type: .error)
                    }
                    continuation.resume(returning: [])
                }
            }
        }
    }
    
    private func getBasePath() -> String {
        // Development path
        return "/Users/nathanhicks/NATHANS APPS/MultiCourtScore"
    }
    
    private func addLog(_ message: String, type: ScanLogEntry.LogType) {
        let entry = ScanLogEntry(timestamp: Date(), message: message, type: type)
        Task { @MainActor in
            scanLogs.append(entry)
            // Keep only last 100 entries
            if scanLogs.count > 100 {
                scanLogs.removeFirst()
            }
        }
    }
    
    // MARK: - Conversion to MatchItem
    
    func createMatchItems(from matches: [VBLMatch]) -> [MatchItem] {
        // First, auto-number matches that need it
        let numberedMatches = autoNumberMatches(matches)
        
        return numberedMatches.compactMap { match -> MatchItem? in
            guard let urlString = match.apiURL,
                  let url = URL(string: urlString) else {
                return nil
            }
            
            return MatchItem(
                apiURL: url,
                label: match.matchNumber,
                team1Name: match.team1,
                team2Name: match.team2,
                team1Seed: match.team1_seed,
                team2Seed: match.team2_seed,
                matchType: match.matchType,
                typeDetail: match.typeDetail,
                scheduledTime: match.startTime,
                matchNumber: match.matchNumber,
                courtNumber: match.court,
                physicalCourt: match.court,  // Track physical court for reassignment
                setsToWin: match.setsToWin,
                pointsPerSet: match.pointsPerSet,
                pointCap: match.pointCap,
                formatText: match.formatText
            )
        }
    }
    
    /// Auto-number matches like "Semifinals", "Quarterfinals" by scheduled time
    private func autoNumberMatches(_ matches: [VBLMatch]) -> [VBLMatch] {
        // Group matches by their base label (e.g., "Semifinals", "Quarterfinals")
        var labelGroups: [String: [VBLMatch]] = [:]
        var otherMatches: [VBLMatch] = []
        
        for match in matches {
            guard let matchNum = match.matchNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !matchNum.isEmpty else {
                otherMatches.append(match)
                continue
            }
            
            // Check if this is a label that needs numbering (no existing number)
            let needsNumbering = matchNum.lowercased().contains("semifinal") ||
                                matchNum.lowercased().contains("quarterfinal") ||
                                matchNum.lowercased().contains("final")
            
            // Only auto-number if there's no existing number
            let hasNumber = matchNum.range(of: #"\d+"#, options: .regularExpression) != nil
            
            if needsNumbering && !hasNumber {
                let baseLabel = matchNum
                if labelGroups[baseLabel] == nil {
                    labelGroups[baseLabel] = []
                }
                labelGroups[baseLabel]?.append(match)
            } else {
                otherMatches.append(match)
            }
        }
        
        // Auto-number each group by scheduled time
        var result: [VBLMatch] = otherMatches
        
        for (baseLabel, groupMatches) in labelGroups {
            // Sort by scheduled time
            let sorted = groupMatches.sorted { a, b in
                guard let timeA = a.startTime, let timeB = b.startTime else {
                    return false
                }
                return compareTimeStrings(timeA, timeB) < 0
            }
            
            // Assign numbers
            for (index, match) in sorted.enumerated() {
                // Use reflection to create a modified copy
                // Since VBLMatch is a struct with let properties, we need to decode/encode
                if let data = try? JSONEncoder().encode(match),
                   var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    dict["matchNumber"] = "\(baseLabel) \(index + 1)"
                    if let newData = try? JSONSerialization.data(withJSONObject: dict),
                       let newMatch = try? JSONDecoder().decode(VBLMatch.self, from: newData) {
                        result.append(newMatch)
                        continue
                    }
                }
                // Fallback: just append original
                result.append(match)
            }
        }
        
        return result
    }
}

// MARK: - Scan Result Codable
extension ScannerViewModel {
    struct ScanResult: Codable {
        let url: String
        let timestamp: String
        let totalMatches: Int?
        let matches: [VBLMatch]
        let status: String
        let error: String?
        let matchType: String?
        let typeDetail: String?
        
        enum CodingKeys: String, CodingKey {
            case url, timestamp, totalMatches = "total_matches", matches, status, error
            case matchType = "match_type", typeDetail = "type_detail"
        }
    }
    
    // Wrapper to handle both single result and array of results from CLI
    struct ScanResultWrapper: Codable {
        let urlsScanned: Int?
        let totalMatches: Int?
        let results: [ScanResult]?
        let matches: [VBLMatch]?
        let status: String?
        
        enum CodingKeys: String, CodingKey {
            case urlsScanned = "urls_scanned"
            case totalMatches = "total_matches"
            case results, matches, status
        }
    }
}
