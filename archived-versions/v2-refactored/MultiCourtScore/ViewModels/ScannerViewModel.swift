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
    
    // MARK: - Scan URLs
    @Published var bracketURLs: [String] = ["", "", "", ""]
    @Published var poolURLs: [String] = ["", ""]
    
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
        let matchNumber: String?
        let court: String?
        let startTime: String?
        let apiURL: String?
        let matchType: String?
        let typeDetail: String?
        
        var displayName: String {
            if let t1 = team1, let t2 = team2, !t1.isEmpty, !t2.isEmpty {
                return "\(t1) vs \(t2)"
            }
            return matchNumber ?? "Match \(index + 1)"
        }
        
        var courtDisplay: String { court ?? "TBD" }
        var timeDisplay: String { startTime ?? "TBD" }
        var hasAPIURL: Bool { apiURL != nil && !apiURL!.isEmpty }
        
        enum CodingKeys: String, CodingKey {
            case index, team1, team2, matchNumber, court, startTime
            case apiURL = "api_url"
            case matchType = "match_type"
            case typeDetail = "type_detail"
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            index = try container.decode(Int.self, forKey: .index)
            team1 = try container.decodeIfPresent(String.self, forKey: .team1)
            team2 = try container.decodeIfPresent(String.self, forKey: .team2)
            matchNumber = try container.decodeIfPresent(String.self, forKey: .matchNumber)
            court = try container.decodeIfPresent(String.self, forKey: .court)
            startTime = try container.decodeIfPresent(String.self, forKey: .startTime)
            apiURL = try container.decodeIfPresent(String.self, forKey: .apiURL)
            matchType = try container.decodeIfPresent(String.self, forKey: .matchType)
            typeDetail = try container.decodeIfPresent(String.self, forKey: .typeDetail)
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
        Dictionary(grouping: scanResults) { $0.courtDisplay }
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
        
        // V2 paths
        let v2VenvPython = "\(basePath)/v2-refactored/Scrapers/venv/bin/python3"
        let v2ScriptPath = "\(basePath)/v2-refactored/Scrapers/vbl_scraper/cli.py"
        let v2WorkingDir = "\(basePath)/v2-refactored/Scrapers"
        
        // V1 fallback paths
        let v1Python = "/usr/bin/python3"
        let v1ScriptPath = "\(basePath)/v1-legacy/vbl_complete_login.py"
        
        // Determine which scraper to use
        let useV2 = FileManager.default.fileExists(atPath: v2VenvPython) &&
                    FileManager.default.fileExists(atPath: v2ScriptPath)
        
        let pythonPath = useV2 ? v2VenvPython : v1Python
        let scriptPath = useV2 ? v2ScriptPath : v1ScriptPath
        let workingDir = useV2 ? v2WorkingDir : basePath
        
        addLog("Using \(useV2 ? "v2" : "v1") scraper", type: .info)
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
                
                self.currentProcess = process
                
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
        return matches.compactMap { match -> MatchItem? in
            guard let urlString = match.apiURL,
                  let url = URL(string: urlString) else {
                return nil
            }
            
            return MatchItem(
                apiURL: url,
                label: match.matchNumber,
                team1Name: match.team1,
                team2Name: match.team2,
                matchType: match.matchType,
                typeDetail: match.typeDetail,
                scheduledTime: match.startTime,
                courtNumber: match.court
            )
        }
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
