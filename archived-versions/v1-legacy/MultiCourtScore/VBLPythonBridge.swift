import Foundation
import SwiftUI

class VBLPythonBridge: ObservableObject {
    @Published var isScanning = false
    @Published var scanProgress = ""
    @Published var scanLogs: [ScanLogEntry] = []
    @Published var lastScanResults: [VBLMatchData] = []
    @Published var errorMessage: String?
    
    struct ScanLogEntry: Identifiable {
        let id = UUID()
        let timestamp = Date()
        let message: String
        let type: LogType
        
        enum LogType {
            case info, success, warning, error, progress
            
            var color: Color {
                switch self {
                case .info: return .primary
                case .success: return .green
                case .warning: return .orange
                case .error: return .red
                case .progress: return .blue
                }
            }
            
            var icon: String {
                switch self {
                case .info: return "ℹ️"
                case .success: return "✅"
                case .warning: return "⚠️"
                case .error: return "❌"
                case .progress: return "🔄"
                }
            }
        }
        
        var timeDisplay: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return formatter.string(from: timestamp)
        }
    }
    
    private let pythonEnvPath = "/Users/nathanhicks/NATHANS APPS/MultiCourtScore/venv/bin/python3"
    private let scriptsPath = "/Users/nathanhicks/NATHANS APPS/MultiCourtScore"
    
    init() {
        // Clear UI state on initialization but preserve any existing results
        scanLogs.removeAll()
        scanProgress = ""
        errorMessage = nil
        
        print("🔍 Initialized VBLPythonBridge - cleared UI state only")
    }
    
    struct VBLMatchData: Codable, Identifiable {
        let id = UUID()
        let index: Int
        let team1: String?
        let team2: String?
        let matchNumber: String?
        let court: String?
        let startTime: String?
        let apiURL: String?
        let previewText: String?
        let matchType: String?
        let typeDetail: String?
        
        enum CodingKeys: String, CodingKey {
            case index
            case team1 = "team1"
            case team2 = "team2"
            case matchNumber = "match_number"
            case court
            case startTime = "time"  // Fixed: JSON uses "time" not "start_time"
            case apiURL = "api_url"
            case previewText = "preview_text"
            case matchType = "match_type"
            case typeDetail = "type_detail"
        }
        
        var displayName: String {
            if let team1 = team1, let team2 = team2 {
                return "\(team1) vs \(team2)"
            } else {
                return previewText ?? "Match \(index + 1)"
            }
        }
        
        var courtDisplay: String {
            return court ?? "TBD"
        }
        
        var timeDisplay: String {
            return startTime ?? "TBD"
        }
    }
    
    struct VBLScanResult: Codable {
        let url: String
        let timestamp: String
        let totalMatches: Int?
        let matches: [VBLMatchData]
        let status: String
        let error: String?
        let matchType: String?
        let typeDetail: String?
        
        enum CodingKeys: String, CodingKey {
            case url, timestamp, status, error
            case totalMatches = "total_matches"
            case matches
            case matchType = "match_type"
            case typeDetail = "type_detail"
        }
    }
    
    private var currentProcess: Process?
    
    func clearScanData() {
        lastScanResults = []
        scanLogs.removeAll()
        scanProgress = ""
        errorMessage = nil
        
        // Delete cached JSON file
        let resultsFile = URL(fileURLWithPath: scriptsPath).appendingPathComponent("complete_workflow_results.json")
        try? FileManager.default.removeItem(at: resultsFile)
        
        print("🧹 Cleared all VBL scan data and cache")
    }
    
    func scanBracket(url: String, username: String? = nil, password: String? = nil) {
        guard !isScanning else {
            print("⚠️ Scan already in progress")
            return
        }
        
        // Only clear UI state before starting new scan, preserve lastScanResults until completion
        scanLogs.removeAll()
        scanProgress = "Initializing scan..."
        errorMessage = nil
        
        isScanning = true
        addLogEntry("🎯 Starting VBL bracket scan", type: .info)
        addLogEntry("📍 Target URL: \(url)", type: .info)
        
        print("🔍 Starting scan - current lastScanResults: \(lastScanResults.count) matches")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performPythonScan(url: url, username: username, password: password)
        }
    }
    
    func scanMultipleURLs(urls: [String], username: String? = nil, password: String? = nil) {
        guard !isScanning else {
            print("⚠️ Scan already in progress")
            return
        }
        
        guard !urls.isEmpty else {
            print("⚠️ No URLs provided for scanning")
            return
        }
        
        // Only clear UI state before starting new scan, preserve lastScanResults until completion
        scanLogs.removeAll()
        scanProgress = "Initializing multi-URL scan..."
        errorMessage = nil
        
        isScanning = true
        addLogEntry("🎯 Starting VBL multi-URL scan", type: .info)
        addLogEntry("📍 Scanning \(urls.count) URLs", type: .info)
        
        for (index, url) in urls.enumerated() {
            addLogEntry("📍 URL \(index + 1): \(url)", type: .info)
        }
        
        print("🔍 Starting multi-URL scan - current lastScanResults: \(lastScanResults.count) matches")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performMultipleURLScan(urls: urls, username: username, password: password)
        }
    }
    
    func cancelScan() {
        print("🛑 Canceling scan...")
        
        // Terminate the Python process if running
        if let process = currentProcess, process.isRunning {
            process.terminate()
            print("🛑 Python process terminated")
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.isScanning = false
            self?.scanProgress = "Scan canceled"
            self?.errorMessage = "Scan was canceled by user"
            self?.currentProcess = nil
        }
    }
    
    private func performMultipleURLScan(urls: [String], username: String? = nil, password: String? = nil) {
        var allMatches: [VBLMatchData] = []
        var hasErrors = false
        var errorMessages: [String] = []
        
        for (index, url) in urls.enumerated() {
            DispatchQueue.main.async { [weak self] in
                self?.scanProgress = "Scanning URL \(index + 1) of \(urls.count): \(url)"
                self?.addLogEntry("🔄 Processing URL \(index + 1) of \(urls.count)", type: .progress)
            }
            
            // Perform scan for this URL synchronously
            let matches = performSingleURLScan(url: url, username: username, password: password)
            
            if !matches.isEmpty {
                allMatches.append(contentsOf: matches)
                DispatchQueue.main.async { [weak self] in
                    self?.addLogEntry("✅ Found \(matches.count) matches from URL \(index + 1)", type: .success)
                }
            } else {
                hasErrors = true
                errorMessages.append("No matches found in URL \(index + 1)")
                DispatchQueue.main.async { [weak self] in
                    self?.addLogEntry("⚠️ No matches found in URL \(index + 1)", type: .warning)
                }
            }
            
            // Small delay between URLs to be respectful
            Thread.sleep(forTimeInterval: 0.5)
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.lastScanResults = allMatches
            
            if allMatches.isEmpty {
                self?.errorMessage = "No matches found in any of the \(urls.count) URLs"
                self?.scanProgress = "❌ No matches found"
                self?.addLogEntry("❌ Multi-URL scan completed with no results", type: .error)
            } else {
                self?.scanProgress = "✅ Multi-URL scan completed - found \(allMatches.count) matches total"
                self?.addLogEntry("✅ Multi-URL scan completed successfully", type: .success)
                self?.addLogEntry("📊 Total matches found: \(allMatches.count)", type: .info)
            }
            
            self?.isScanning = false
            self?.currentProcess = nil
        }
    }
    
    private func performSingleURLScan(url: String, username: String? = nil, password: String? = nil) -> [VBLMatchData] {
        let process = Process()
        let pipe = Pipe()
        let errorPipe = Pipe()
        
        // Store process reference for cancellation
        self.currentProcess = process
        
        // Set up the python command
        process.executableURL = URL(fileURLWithPath: pythonEnvPath)
        
        // Determine which scraper to use based on URL
        let scriptName = url.lowercased().contains("/pools/") ? "vbl_pool_scraper.py" : "vbl_complete_login.py"
        
        var arguments = [
            "\(scriptsPath)/\(scriptName)",
            url
        ]
        
        if let username = username, let password = password {
            arguments.append(contentsOf: [username, password])
        }
        
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: scriptsPath)
        process.standardOutput = pipe
        process.standardError = errorPipe
        
        var matches: [VBLMatchData] = []
        
        do {
            try process.run()
            
            // Monitor output
            let outputHandle = pipe.fileHandleForReading
            let errorHandle = errorPipe.fileHandleForReading
            
            // Read output in chunks to show progress
            var outputData = Data()
            var errorData = Data()
            
            while process.isRunning {
                Thread.sleep(forTimeInterval: 0.05)
                
                let availableOutput = outputHandle.availableData
                if !availableOutput.isEmpty {
                    outputData.append(availableOutput)
                    if let outputString = String(data: availableOutput, encoding: .utf8) {
                        DispatchQueue.main.async { [weak self] in
                            self?.updateProgress(from: outputString)
                        }
                    }
                }
                
                let availableError = errorHandle.availableData
                if !availableError.isEmpty {
                    errorData.append(availableError)
                }
            }
            
            process.waitUntilExit()
            
            // Get any remaining output
            outputData.append(outputHandle.readDataToEndOfFile())
            errorData.append(errorHandle.readDataToEndOfFile())
            
            let exitCode = process.terminationStatus
            
            // Try to load the results JSON file
            let resultsFile = URL(fileURLWithPath: scriptsPath).appendingPathComponent("complete_workflow_results.json")
            
            if FileManager.default.fileExists(atPath: resultsFile.path) {
                let jsonData = try Data(contentsOf: resultsFile)
                let scanResult = try JSONDecoder().decode(VBLScanResult.self, from: jsonData)
                
                if scanResult.status == "success" {
                    matches = scanResult.matches
                }
            }
            
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.addLogEntry("❌ Error scanning \(url): \(error.localizedDescription)", type: .error)
            }
        }
        
        return matches
    }

    private func performPythonScan(url: String, username: String? = nil, password: String? = nil) {
        let process = Process()
        let pipe = Pipe()
        let errorPipe = Pipe()
        
        // Store process reference for cancellation
        self.currentProcess = process
        
        // Set up the python command
        process.executableURL = URL(fileURLWithPath: pythonEnvPath)
        
        var arguments = [
            "\(scriptsPath)/vbl_complete_login.py",
            url
        ]
        
        if let username = username, let password = password {
            arguments.append(contentsOf: [username, password])
        }
        
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: scriptsPath)
        process.standardOutput = pipe
        process.standardError = errorPipe
        
        DispatchQueue.main.async { [weak self] in
            self?.scanProgress = "Starting Python scraper..."
            self?.addLogEntry("🚀 Launching Playwright browser", type: .progress)
        }
        
        do {
            try process.run()
            
            // Monitor output
            let outputHandle = pipe.fileHandleForReading
            let errorHandle = errorPipe.fileHandleForReading
            
            // Read output in chunks to show progress
            var outputData = Data()
            var errorData = Data()
            
            while process.isRunning {
                Thread.sleep(forTimeInterval: 0.05)  // Even faster polling for real-time updates
                
                let availableOutput = outputHandle.availableData
                if !availableOutput.isEmpty {
                    outputData.append(availableOutput)
                    if let outputString = String(data: availableOutput, encoding: .utf8) {
                        DispatchQueue.main.async { [weak self] in
                            self?.updateProgress(from: outputString)
                        }
                    }
                }
                
                let availableError = errorHandle.availableData
                if !availableError.isEmpty {
                    errorData.append(availableError)
                }
            }
            
            process.waitUntilExit()
            
            // Get any remaining output
            outputData.append(outputHandle.readDataToEndOfFile())
            errorData.append(errorHandle.readDataToEndOfFile())
            
            let exitCode = process.terminationStatus
            let outputString = String(data: outputData, encoding: .utf8) ?? ""
            let errorString = String(data: errorData, encoding: .utf8) ?? ""
            
            DispatchQueue.main.async { [weak self] in
                self?.processScanResults(exitCode: exitCode, output: outputString, error: errorString)
            }
            
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = "Failed to start Python scraper: \(error.localizedDescription)"
                self?.isScanning = false
                self?.scanProgress = "Scan failed"
            }
        }
    }
    
    private func addLogEntry(_ message: String, type: ScanLogEntry.LogType) {
        let entry = ScanLogEntry(message: message, type: type)
        
        // Force immediate UI update for each log entry
        DispatchQueue.main.async { [weak self] in
            self?.scanLogs.append(entry)
            
            // Keep only last 100 log entries for more detailed console-style logging
            if let self = self, self.scanLogs.count > 100 {
                self.scanLogs.removeFirst(self.scanLogs.count - 100)
            }
            
            // Force UI refresh by updating a dummy property
            self?.objectWillChange.send()
        }
    }
    
    private func updateProgress(from output: String) {
        // Extract progress messages from Python output - this is already on main queue
        let lines = output.components(separatedBy: .newlines)
        
        for line in lines {
            let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                // Process each line immediately since we're already on main queue
                processLogLine(cleaned)
            }
        }
    }
    
    private func processLogLine(_ cleaned: String) {
        // Determine log type based on content with enhanced patterns
        let logType: ScanLogEntry.LogType
        if cleaned.contains("✅") || cleaned.contains("Success") || cleaned.contains("completed") {
            logType = .success
        } else if cleaned.contains("❌") || cleaned.contains("Error") || cleaned.contains("Failed") || cleaned.contains("failed") {
            logType = .error
        } else if cleaned.contains("⚠️") || cleaned.contains("Warning") || cleaned.contains("warning") {
            logType = .warning
        } else if cleaned.contains("🔍") || cleaned.contains("📍") || cleaned.contains("⏳") || 
                 cleaned.contains("🎯") || cleaned.contains("👆") || cleaned.contains("🏆") ||
                 cleaned.contains("🚀") || cleaned.contains("🌐") || cleaned.contains("🔐") ||
                 cleaned.contains("🎭") || cleaned.contains("📋") || cleaned.contains("💾") ||
                 cleaned.contains("Processing match") || cleaned.contains("Step") ||
                 cleaned.contains("Clicking") || cleaned.contains("Scanning") ||
                 cleaned.contains("Finding") || cleaned.contains("Loading") {
            logType = .progress
        } else if cleaned.contains("🔧") || cleaned.contains("Corrected") || cleaned.contains("Parsed") ||
                 cleaned.contains("ℹ️") || cleaned.contains("Found") || cleaned.contains("Extracted") {
            logType = .info
        } else {
            // Show all non-empty lines as info
            logType = .info
        }
        
        // Add to log and update current progress
        addLogEntry(cleaned, type: logType)
        scanProgress = cleaned
    }
    
    private func processScanResults(exitCode: Int32, output: String, error: String) {
        print("🔍 Python script finished with exit code: \(exitCode)")
        print("📤 Output: \(output)")
        
        if !error.isEmpty {
            print("⚠️ Error output: \(error)")
        }
        
        // Try to load the results JSON file
        let resultsFile = URL(fileURLWithPath: scriptsPath).appendingPathComponent("complete_workflow_results.json")
        
        do {
            let jsonData = try Data(contentsOf: resultsFile)
            print("📄 JSON file loaded, size: \(jsonData.count) bytes")
            
            let scanResult = try JSONDecoder().decode(VBLScanResult.self, from: jsonData)
            print("🔍 Decoded JSON - Status: \(scanResult.status), Matches: \(scanResult.matches.count)")
            
            lastScanResults = scanResult.matches
            print("💾 Set lastScanResults to \(lastScanResults.count) matches")
            
            // Debug: Print first few matches
            for (index, match) in lastScanResults.prefix(3).enumerated() {
                print("  Match \(index + 1): \(match.displayName) - Court: \(match.courtDisplay)")
            }
            
            if scanResult.status == "success" {
                scanProgress = "✅ Scan completed - found \(scanResult.matches.count) matches"
                addLogEntry("✅ Successfully loaded \(scanResult.matches.count) matches from JSON", type: .success)
            } else {
                errorMessage = scanResult.error ?? "Scan completed but no matches found"
                scanProgress = "⚠️ Scan completed with issues"
                addLogEntry("⚠️ Scan completed with issues: \(scanResult.error ?? "unknown")", type: .warning)
            }
            
        } catch {
            errorMessage = "Failed to parse scan results: \(error.localizedDescription)"
            scanProgress = "❌ Failed to load results"
        }
        
        isScanning = false
        currentProcess = nil
    }
    
    func createMatchItems(from matches: [VBLMatchData]) -> [MatchItem] {
        return matches.compactMap { match in
            guard let apiURLString = match.apiURL,
                  let apiURL = URL(string: apiURLString) else {
                return nil
            }
            
            return MatchItem(
                apiURL: apiURL,
                label: match.displayName,
                team1Name: match.team1,
                team2Name: match.team2
            )
        }
    }
    
    func testPythonEnvironment() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let process = Process()
            let pipe = Pipe()
            
            process.executableURL = URL(fileURLWithPath: self.pythonEnvPath)
            process.arguments = ["-c", "import playwright; print('✅ Playwright available'); import requests; print('✅ Requests available'); print('🎉 Python environment ready!')"]
            process.standardOutput = pipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                
                DispatchQueue.main.async {
                    print("🐍 Python environment test result:")
                    print(output)
                }
                
            } catch {
                DispatchQueue.main.async {
                    print("❌ Python environment test failed: \(error)")
                }
            }
        }
    }
}