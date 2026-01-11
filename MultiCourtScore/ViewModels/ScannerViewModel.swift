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
        // Live scores
        let team1_score: Int?
        let team2_score: Int?
        
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
            case index, team1, team2, team1_seed, team2_seed, court, startTime, startDate
            case matchNumber = "match_number"
            case apiURL = "api_url"
            case matchType = "match_type"
            case typeDetail = "type_detail"
            case setsToWin, pointsPerSet, pointCap, formatText
            case team1_score, team2_score
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
            team1_score = try container.decodeIfPresent(Int.self, forKey: .team1_score)
            team2_score = try container.decodeIfPresent(Int.self, forKey: .team2_score)
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
    
    /// Compare two day strings (e.g., "Sat", "Sun", "Friday", "1/10")
    /// Returns: negative if a < b, positive if a > b, 0 if equal
    private func compareDayStrings(_ a: String?, _ b: String?) -> Int {
        guard let dayA = a?.trimmingCharacters(in: .whitespaces).lowercased(),
              let dayB = b?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return 0  // If either is nil, treat as equal
        }
        
        // Day abbreviations in week order (typical tournament is Thu-Sun)
        let dayOrder: [String: Int] = [
            "thu": 0, "thursday": 0,
            "fri": 1, "friday": 1,
            "sat": 2, "saturday": 2,
            "sun": 3, "sunday": 3,
            "mon": 4, "monday": 4,
            "tue": 5, "tuesday": 5,
            "wed": 6, "wednesday": 6
        ]
        
        if let orderA = dayOrder[dayA], let orderB = dayOrder[dayB] {
            return orderA - orderB
        }
        
        // Try parsing as date (e.g., "1/10", "01-11")
        let datePattern = #"(\d{1,2})[/\-](\d{1,2})"#
        if let regex = try? NSRegularExpression(pattern: datePattern),
           let matchA = regex.firstMatch(in: dayA, range: NSRange(dayA.startIndex..., in: dayA)),
           let matchB = regex.firstMatch(in: dayB, range: NSRange(dayB.startIndex..., in: dayB)) {
            let monthA = Int(dayA[Range(matchA.range(at: 1), in: dayA)!]) ?? 0
            let monthB = Int(dayB[Range(matchB.range(at: 1), in: dayB)!]) ?? 0
            let dayNumA = Int(dayA[Range(matchA.range(at: 2), in: dayA)!]) ?? 0
            let dayNumB = Int(dayB[Range(matchB.range(at: 2), in: dayB)!]) ?? 0
            
            if monthA != monthB { return monthA - monthB }
            return dayNumA - dayNumB
        }
        
        // Fallback to string comparison
        return dayA.compare(dayB).rawValue
    }
    
    /// Compare two matches by day first, then time
    private func compareByDayAndTime(_ a: VBLMatch, _ b: VBLMatch) -> Int {
        // First compare by day
        let dayCompare = compareDayStrings(a.startDate, b.startDate)
        if dayCompare != 0 { return dayCompare }
        
        // Then compare by time
        guard let timeA = a.startTime, let timeB = b.startTime else { return 0 }
        return compareTimeStrings(timeA, timeB)
    }
    
    // MARK: - Actions
    
    func startScan() {
        guard canScan else { return }
        
        isScanning = true
        scanLogs.removeAll()
        scanResults = []
        errorMessage = nil
        scanProgress = "Initializing scan..."
        
        print("🚀 START SCAN CALLED - URLs: \(allURLs)")
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
        Task { @MainActor in
            self.addLog("🔍 performScan() called", type: .info)
        }
        
        let basePath = getBasePath()
        
        // Venv is at project root (NOT in Scrapers folder - that causes Xcode build errors)
        let venvPython = "\(basePath)/scraper_venv/bin/python3"
        let scriptPath = "\(basePath)/MultiCourtScore/Scrapers/vbl_scraper/cli.py"
        let workingDir = "\(basePath)/MultiCourtScore/Scrapers"
        
        // Fallback to system Python if venv doesn't exist
        let systemPython = "/usr/bin/python3"
        
        // Determine which Python to use
        let useVenv = FileManager.default.fileExists(atPath: venvPython) &&
                      FileManager.default.fileExists(atPath: scriptPath)
        
        let pythonPath = useVenv ? venvPython : systemPython
        
        addLog("Using \(useVenv ? "venv" : "system") Python", type: .info)
        addLog("Python: \(pythonPath)", type: .info)
        addLog("Script: \(scriptPath)", type: .info)
        
        // PARALLEL MODE: Send all URLs at once for ~4x speedup
        if allURLs.count > 1 {
            scanProgress = "🚀 Parallel scanning \(allURLs.count) URLs..."
            addLog("🚀 Using PARALLEL mode for \(allURLs.count) URLs", type: .info)
            
            let matches = await scanAllURLsParallel(
                allURLs,
                pythonPath: pythonPath,
                scriptPath: scriptPath,
                workingDir: workingDir
            )
            
            if !matches.isEmpty {
                scanResults.append(contentsOf: matches)
                addLog("Found \(matches.count) matches total", type: .success)
            } else {
                addLog("No matches found", type: .warning)
            }
        } else {
            // Single URL - use standard mode
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
            }
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
                
                // Validate paths before running
                Task { @MainActor in
                    self.addLog("Validating paths...", type: .info)
                    self.addLog("Python exists: \(FileManager.default.fileExists(atPath: pythonPath))", type: .info)
                    self.addLog("Script exists: \(FileManager.default.fileExists(atPath: scriptPath))", type: .info)
                    self.addLog("Working dir exists: \(FileManager.default.fileExists(atPath: workingDir))", type: .info)
                }
                
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
                    self.addLog("Launching: \(pythonPath) -m vbl_scraper.cli \(url) -o \(outputFile.path)", type: .info)
                }
                
                // Synchronous validation before launching
                print("📍 Python path: \(pythonPath)")
                print("📍 Python exists: \(FileManager.default.fileExists(atPath: pythonPath))")
                print("📍 Script path: \(scriptPath)")
                print("📍 Script exists: \(FileManager.default.fileExists(atPath: scriptPath))")
                print("📍 Working dir: \(workingDir)")
                print("📍 Output file: \(outputFile.path)")
                print("📍 About to call process.run()...")
                
                do {
                    Task { @MainActor in
                        self.addLog("Running Python process...", type: .info)
                    }
                    
                    try process.run()
                    print("✅ process.run() succeeded")
                    process.waitUntilExit()
                    
                    let exitCode = process.terminationStatus
                    print("📊 Exit code: \(exitCode)")
                    
                    // Read stderr for debugging
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    if !errorData.isEmpty, let errorString = String(data: errorData, encoding: .utf8) {
                        print("🔴 Python stderr:\n\(errorString)")
                        Task { @MainActor in
                            for line in errorString.split(separator: "\n").prefix(5) {
                                self.addLog("Python: \(line)", type: .warning)
                            }
                        }
                    }
                    
                    // Read stdout too
                    let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                    if !outputData.isEmpty, let outputString = String(data: outputData, encoding: .utf8) {
                        print("📗 Python stdout:\n\(outputString)")
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
                        self.addLog("Process launch error: \(error.localizedDescription)", type: .error)
                        self.addLog("Error details: \(error)", type: .error)
                    }
                    continuation.resume(returning: [])
                }
            }
        }
    }
    
    /// Scan all URLs in parallel using --parallel flag (4x faster for multiple brackets)
    private func scanAllURLsParallel(_ urls: [String], pythonPath: String, scriptPath: String, workingDir: String) async -> [VBLMatch] {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                let errorPipe = Pipe()
                
                // Generate unique output file
                let outputFile = URL(fileURLWithPath: workingDir)
                    .appendingPathComponent("parallel_results_\(UUID().uuidString.prefix(8)).json")
                
                process.executableURL = URL(fileURLWithPath: pythonPath)
                
                // Build arguments: python -m vbl_scraper.cli url1 url2 url3 --parallel -o output.json
                var args = ["-m", "vbl_scraper.cli"]
                args.append(contentsOf: urls)
                args.append("--parallel")
                args.append("-o")
                args.append(outputFile.path)
                
                process.arguments = args
                process.currentDirectoryURL = URL(fileURLWithPath: workingDir)
                process.standardOutput = pipe
                process.standardError = errorPipe
                
                var env = ProcessInfo.processInfo.environment
                env["PYTHONPATH"] = workingDir
                process.environment = env
                
                Task { @MainActor in
                    self.currentProcess = process
                    self.addLog("🚀 Parallel scan: \(urls.count) URLs", type: .info)
                }
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    let exitCode = process.terminationStatus
                    print("📊 Parallel scan exit code: \(exitCode)")
                    
                    // Read stderr for any errors
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    if !errorData.isEmpty, let errorString = String(data: errorData, encoding: .utf8) {
                        print("⚠️ Parallel scan stderr:\n\(errorString)")
                        Task { @MainActor in
                            self.addLog("Scan output: \(errorString.prefix(200))", type: .info)
                        }
                    }
                    
                    // Parse results - parallel mode returns aggregated results
                    if let data = try? Data(contentsOf: outputFile),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        
                        // Clean up temp file
                        try? FileManager.default.removeItem(at: outputFile)
                        
                        // Extract matches from all results
                        var allMatches: [VBLMatch] = []
                        
                        if let results = json["results"] as? [[String: Any]] {
                            for result in results {
                                if let matchesData = result["matches"] as? [[String: Any]] {
                                    let matchType = result["match_type"] as? String
                                    let typeDetail = result["type_detail"] as? String
                                    
                                    for matchDict in matchesData {
                                        if let match = self.parseVBLMatch(from: matchDict, matchType: matchType, typeDetail: typeDetail) {
                                            allMatches.append(match)
                                        }
                                    }
                                }
                            }
                        }
                        
                        Task { @MainActor in
                            self.addLog("Parallel scan found \(allMatches.count) total matches", type: .success)
                        }
                        
                        continuation.resume(returning: allMatches)
                    } else {
                        Task { @MainActor in
                            self.addLog("Could not parse parallel results", type: .error)
                        }
                        continuation.resume(returning: [])
                    }
                } catch {
                    Task { @MainActor in
                        self.addLog("Parallel scan error: \(error)", type: .error)
                    }
                    continuation.resume(returning: [])
                }
            }
        }
    }
    
    /// Parse a JSON dictionary into a VBLMatch using JSONDecoder
    nonisolated private func parseVBLMatch(from dict: [String: Any], matchType: String?, typeDetail: String?) -> VBLMatch? {
        // Add match_type and type_detail to the dictionary if provided
        var enrichedDict = dict
        if let matchType = matchType, enrichedDict["match_type"] == nil {
            enrichedDict["match_type"] = matchType
        }
        if let typeDetail = typeDetail, enrichedDict["type_detail"] == nil {
            enrichedDict["type_detail"] = typeDetail
        }
        
        // Convert dictionary to JSON data and decode
        guard let jsonData = try? JSONSerialization.data(withJSONObject: enrichedDict),
              let match = try? JSONDecoder().decode(VBLMatch.self, from: jsonData) else {
            return nil
        }
        
        return match
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
            
            // For the label: use matchNumber if we have actual team names,
            // otherwise use the full displayName (e.g., "Match 7 Winner vs Match 8 Winner")
            let hasTeamNames = match.team1 != nil && match.team2 != nil && 
                              !match.team1!.isEmpty && !match.team2!.isEmpty
            let labelText = hasTeamNames ? match.matchNumber : match.displayName
            
            return MatchItem(
                apiURL: url,
                label: labelText,
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
                formatText: match.formatText,
                team1_score: match.team1_score,
                team2_score: match.team2_score
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
            // Sort by day first, then time (prevents Sunday 7AM appearing before Saturday 8PM)
            let sorted = groupMatches.sorted { a, b in
                return compareByDayAndTime(a, b) < 0
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
