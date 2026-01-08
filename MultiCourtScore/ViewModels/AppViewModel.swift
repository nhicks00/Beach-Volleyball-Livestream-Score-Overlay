//
//  AppViewModel.swift
//  MultiCourtScore v2
//
//  Main application view model with improved state management
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    // MARK: - Published State
    @Published private(set) var courts: [Court] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: AppError?
    @Published var scannerViewModel = ScannerViewModel()
    
    // MARK: - Services
    private let webSocketHub: WebSocketHub
    private let configStore: ConfigStore
    private let apiClient: APIClient
    private let scoreCache: ScoreCache
    
    // MARK: - Private State
    private var pollingTimers: [Int: Timer] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var lastQueueRefreshTimes: [Int: Date] = [:]
    
    // Inactivity tracking
    private var lastScoreSnapshot: [Int: (pts1: Int, pts2: Int, s1: Int, s2: Int)] = [:]
    private var lastScoreChangeTime: [Int: Date] = [:]
    
    // MARK: - Initialization
    
    init() {
        self.webSocketHub = WebSocketHub.shared
        self.configStore = ConfigStore()
        self.apiClient = APIClient()
        self.scoreCache = ScoreCache()
        
        loadConfiguration()
        ensureAllCourtsExist()
    }
    
    // MARK: - Services Lifecycle
    
    func startServices() {
        Task {
            await webSocketHub.start(with: self, port: NetworkConstants.webSocketPort)
            print("🚀 MultiCourtScore v2 services started")
        }
    }
    
    func stopServices() {
        stopAllPolling()
        webSocketHub.stop()
        saveConfiguration()
    }
    
    // MARK: - Court Access
    
    func court(for id: Int) -> Court? {
        return courts.first { $0.id == id }
    }
    
    func courtIndex(for id: Int) -> Int? {
        return courts.firstIndex { $0.id == id }
    }
    
    var activeCourts: [Court] {
        return courts.filter { $0.status == .live }
    }
    
    var pollingCourts: [Court] {
        return courts.filter { $0.status.isPolling }
    }
    
    // MARK: - Court Management
    
    func renameCourt(_ courtId: Int, to newName: String) {
        guard let idx = courtIndex(for: courtId) else { return }
        courts[idx].name = newName
        saveConfiguration()
    }
    
    func replaceQueue(_ courtId: Int, with items: [MatchItem], startIndex: Int? = 0) {
        guard let idx = courtIndex(for: courtId) else { return }
        courts[idx].queue = items
        courts[idx].activeIndex = items.isEmpty ? nil : (startIndex ?? 0)
        courts[idx].status = .idle  // Require manual start - don't auto-set to waiting
        courts[idx].lastSnapshot = nil
        courts[idx].liveSince = nil
        saveConfiguration()
    }
    
    func appendToQueue(_ courtId: Int, items: [MatchItem]) {
        guard let idx = courtIndex(for: courtId) else { return }
        courts[idx].queue.append(contentsOf: items)
        if courts[idx].activeIndex == nil && !items.isEmpty {
            courts[idx].activeIndex = 0
        }
        saveConfiguration()
    }
    
    func clearQueue(_ courtId: Int) {
        replaceQueue(courtId, with: [])
        stopPolling(for: courtId)
    }
    
    func clearAllQueues() {
        stopAllPolling()
        for i in courts.indices {
            courts[i].queue = []
            courts[i].activeIndex = nil
            courts[i].status = .idle
            courts[i].lastSnapshot = nil
            courts[i].liveSince = nil
        }
        saveConfiguration()
    }
    
    // MARK: - Polling Control
    
    func startPolling(for courtId: Int) {
        // Ensure services are running
        if !webSocketHub.isRunning {
             startServices()
        }
        
        guard let idx = courtIndex(for: courtId) else { return }
        guard !courts[idx].queue.isEmpty else { return }
        
        if courts[idx].activeIndex == nil {
            courts[idx].activeIndex = 0
        }
        courts[idx].status = .waiting
        courts[idx].errorMessage = nil
        
        // Cancel existing timer
        pollingTimers[courtId]?.invalidate()
        
        // Staggered polling with jitter to avoid thundering herd
        let jitter = Double((courtId * 317) % 1200) / 1000.0
        let interval = NetworkConstants.pollingInterval + Double((courtId * 97) % 800) / 1000.0
        
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(jitter * 1_000_000_000))
                await self?.pollOnce(courtId)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollingTimers[courtId] = timer
        
        saveConfiguration()
        print("▶️ Started polling for court \(courtId)")
    }
    
    func stopPolling(for courtId: Int) {
        pollingTimers[courtId]?.invalidate()
        pollingTimers[courtId] = nil
        
        if let idx = courtIndex(for: courtId) {
            courts[idx].status = .idle
            courts[idx].liveSince = nil
        }
        saveConfiguration()
        print("⏹️ Stopped polling for court \(courtId)")
    }
    
    func startAllPolling() {
        // Ensure services are running
        if !webSocketHub.isRunning {
             startServices()
        }

        for court in courts where !court.queue.isEmpty {
            startPolling(for: court.id)
        }
    }
    
    func stopAllPolling() {
        // Stop all active timers
        for courtId in pollingTimers.keys {
            stopPolling(for: courtId)
        }
        
        // Also reset status for any court with a queue (in case timer wasn't created yet)
        for idx in courts.indices where !courts[idx].queue.isEmpty {
            if courts[idx].status != .idle {
                courts[idx].status = .idle
                courts[idx].liveSince = nil
            }
        }
        saveConfiguration()
    }
    
    // MARK: - Navigation
    
    func skipToNext(_ courtId: Int) {
        guard let idx = courtIndex(for: courtId) else { return }
        guard let activeIdx = courts[idx].activeIndex else { return }
        
        let nextIndex = activeIdx + 1
        if nextIndex < courts[idx].queue.count {
            courts[idx].activeIndex = nextIndex
            
            // Preserve polling state: if already polling, go to waiting; otherwise stay idle
            if courts[idx].status.isPolling {
                courts[idx].status = .waiting
            } else {
                courts[idx].status = .idle
            }
            
            courts[idx].liveSince = nil
            courts[idx].lastSnapshot = nil
            saveConfiguration()
        }
    }
    
    func skipToPrevious(_ courtId: Int) {
        guard let idx = courtIndex(for: courtId) else { return }
        guard let activeIdx = courts[idx].activeIndex, activeIdx > 0 else { return }
        
        courts[idx].activeIndex = activeIdx - 1
        
        // Preserve polling state: if already polling, go to waiting; otherwise stay idle
        if courts[idx].status.isPolling {
            courts[idx].status = .waiting
        } else {
            courts[idx].status = .idle
        }
        
        courts[idx].liveSince = nil
        courts[idx].lastSnapshot = nil
        saveConfiguration()
    }
    
    // MARK: - Overlay URL
    
    func overlayURL(for courtId: Int) -> String {
        return "http://localhost:\(NetworkConstants.webSocketPort)/overlay/court/\(courtId)/"
    }
    
    // MARK: - Private Methods
    
    private func pollOnce(_ courtId: Int) async {
        guard let idx = courtIndex(for: courtId),
              courts[idx].status != .idle else {
            stopPolling(for: courtId)
            return
        }
        
        guard let activeIdx = courts[idx].activeIndex,
              activeIdx < courts[idx].queue.count else {
            return
        }
        
        let matchItem = courts[idx].queue[activeIdx]
        
        do {
            let data = try await scoreCache.get(matchItem.apiURL)
            // Pass matchItem to normalizeData to access seeds
            let snapshot = normalizeData(data, courtId: courtId, currentMatch: matchItem)
            
            // Inactivity Check: Has score CHANGED (points OR sets) since last poll?
            let currentS1 = snapshot.team1Score
            let currentS2 = snapshot.team2Score
            let currentP1 = snapshot.setHistory.last?.team1Score ?? 0
            let currentP2 = snapshot.setHistory.last?.team2Score ?? 0
            let prevData = lastScoreSnapshot[courtId]
            
            if prevData == nil || 
               prevData?.pts1 != currentP1 || prevData?.pts2 != currentP2 ||
               prevData?.s1 != currentS1 || prevData?.s2 != currentS2 {
                // Point or set changed: update tracker
                lastScoreSnapshot[courtId] = (pts1: currentP1, pts2: currentP2, s1: currentS1, s2: currentS2)
                lastScoreChangeTime[courtId] = Date()
            }
            
            let timeSinceLastScore = Date().timeIntervalSince(lastScoreChangeTime[courtId] ?? Date())
            let isStale = timeSinceLastScore >= AppConfig.staleMatchTimeout // 15 mins
            
            let previousStatus = courts[idx].status
            let newStatus = determineStatus(from: snapshot)
            
            // Update stopwatch
            if previousStatus != .live && newStatus == .live {
                courts[idx].liveSince = Date()
            }
            if newStatus != .live {
                courts[idx].liveSince = nil
            }
            
            // Handle match completion OR Stale timeout
            if snapshot.isFinal || isStale {
                if isStale && !snapshot.isFinal {
                    print("🚨 Court \(courtId) match is stale (no score change for 15m). Auto-advancing.")
                }
                
                courts[idx].status = .finished
                courts[idx].lastSnapshot = snapshot
                
                // Record when match finished (if not already recorded)
                if courts[idx].finishedAt == nil {
                    courts[idx].finishedAt = Date()
                }
                
                // Check if we should advance to next match
                let nextIndex = activeIdx + 1
                if nextIndex < courts[idx].queue.count {
                    let holdDuration = AppConfig.holdScoreDuration  // 3 minutes
                    let timeSinceFinish = Date().timeIntervalSince(courts[idx].finishedAt ?? Date())
                    
                    // Advance if: hold time exceeded OR next match has started OR match was stale
                    let holdExpired = timeSinceFinish >= holdDuration
                    let nextStarted = await nextMatchHasStarted(courts[idx].queue[nextIndex])
                    
                    if holdExpired || nextStarted || isStale {
                        // Advance to next match
                        courts[idx].activeIndex = nextIndex
                        courts[idx].status = .waiting
                        courts[idx].liveSince = nil
                        courts[idx].finishedAt = nil  // Reset for next match
                        lastScoreSnapshot[courtId] = nil // Reset tracker for new match
                        lastScoreChangeTime[courtId] = nil
                        print("⏭️ Auto-advanced court \(courtId) to match \(nextIndex + 1)")
                    }
                }
            } else {
                courts[idx].status = newStatus
                courts[idx].lastSnapshot = snapshot
                courts[idx].finishedAt = nil  // Clear if match is not final
            }
            
            
            // Periodically refresh metadata for queued matches (every 60s)
            let lastRefresh = lastQueueRefreshTimes[courtId] ?? Date.distantPast
            if Date().timeIntervalSince(lastRefresh) > 60 {
                await refreshQueueMetadata(for: courtId)
                lastQueueRefreshTimes[courtId] = Date()
            }

            courts[idx].lastPollTime = Date()
            courts[idx].errorMessage = nil
            
        } catch {
            courts[idx].errorMessage = error.localizedDescription
            // Don't change to error status on single failure
            print("⚠️ Poll error for court \(courtId): \(error.localizedDescription)")
        }
    }
    
    private func nextMatchHasStarted(_ match: MatchItem) async -> Bool {
        do {
            let data = try await apiClient.fetchData(from: match.apiURL) // Uses VBL match URL
            let snapshot = normalizeData(data, courtId: 0, currentMatch: match)
            return snapshot.hasStarted
        } catch {
            return false
        }
    }
    
    // Refresh TBD names in the queue
    private func refreshQueueMetadata(for courtId: Int) async {
        guard let idx = courtIndex(for: courtId) else { return }
        
        // Iterate over future matches
        let startIndex = (courts[idx].activeIndex ?? -1) + 1
        guard startIndex < courts[idx].queue.count else { return }
        
        for i in startIndex..<courts[idx].queue.count {
            let match = courts[idx].queue[i]
            
            do {
                // Fetch fresh data for the queued match
                let data = try await apiClient.fetchData(from: match.apiURL)
                let snapshot = normalizeData(data, courtId: 0, currentMatch: match)
                
                // Update names if changed
                if snapshot.team1Name != match.team1Name || snapshot.team2Name != match.team2Name {
                    print("🔄 Updated queue metadata for match \(i): \(snapshot.team1Name) vs \(snapshot.team2Name)")
                    courts[idx].queue[i].team1Name = snapshot.team1Name
                    courts[idx].queue[i].team2Name = snapshot.team2Name
                }
            } catch {
                print("⚠️ Failed to refresh queue metadata: \(error.localizedDescription)")
            }
        }
    }
    
    private func determineStatus(from snapshot: ScoreSnapshot) -> CourtStatus {
        if snapshot.isFinal {
            return .finished
        } else if snapshot.hasStarted {
            return .live
        } else {
            return .waiting
        }
    }
    
    // Updated signature: accepts optional currentMatch to extract seeds
    private func normalizeData(_ data: Data, courtId: Int, currentMatch: MatchItem? = nil) -> ScoreSnapshot {
        guard let jsonObj = try? JSONSerialization.jsonObject(with: data) else {
            return .empty(courtId: courtId)
        }
        
        // Handle vMix array format
        if let array = jsonObj as? [[String: Any]] {
            return normalizeArrayFormat(array, courtId: courtId, currentMatch: currentMatch)
        }
        
        // Handle dictionary format
        if let dict = jsonObj as? [String: Any] {
            return normalizeDictFormat(dict, courtId: courtId, currentMatch: currentMatch)
        }
        
        return .empty(courtId: courtId)
    }
    
    private func normalizeArrayFormat(_ array: [[String: Any]], courtId: Int, currentMatch: MatchItem?) -> ScoreSnapshot {
        guard array.count >= 2 else { return .empty(courtId: courtId) }
        
        let t1 = array[0]
        let t2 = array[1]
        
        let name1 = (t1["teamName"] as? String) ?? "Team A"
        let name2 = (t2["teamName"] as? String) ?? "Team B"
        
        // Get format from match or use defaults
        let pointsPerSet = currentMatch?.pointsPerSet ?? 21
        let pointCap = currentMatch?.pointCap
        let setsToWin = currentMatch?.setsToWin ?? 2
        
        // Parse set scores from "gameX" keys as ints or strings
        // Based on user screenshot: "game1": 15
        let g1a_raw = t1["game1"] as? Int ?? Int(t1["game1"] as? String ?? "0") ?? 0
        let g1b_raw = t2["game1"] as? Int ?? Int(t2["game1"] as? String ?? "0") ?? 0
        let g2a_raw = t1["game2"] as? Int ?? Int(t1["game2"] as? String ?? "0") ?? 0
        let g2b_raw = t2["game2"] as? Int ?? Int(t2["game2"] as? String ?? "0") ?? 0
        let g3a_raw = t1["game3"] as? Int ?? Int(t1["game3"] as? String ?? "0") ?? 0
        let g3b_raw = t2["game3"] as? Int ?? Int(t2["game3"] as? String ?? "0") ?? 0
        
        // Helper to check if a set is complete
        func isSetComplete(_ a: Int, _ b: Int, target: Int, cap: Int?) -> Bool {
            let maxScore = max(a, b)
            let diff = abs(a - b)
            // If cap exists and reached, set is complete
            if let c = cap, maxScore >= c { return true }
            // Otherwise need target + 2pt lead
            return maxScore >= target && diff >= 2
        }
        
        // Determine current set and match score
        var setHistory: [SetScore] = []
        var score1 = 0
        var score2 = 0
        
        // Set 1
        if g1a_raw > 0 || g1b_raw > 0 {
            let complete = isSetComplete(g1a_raw, g1b_raw, target: pointsPerSet, cap: pointCap)
            setHistory.append(SetScore(setNumber: 1, team1Score: g1a_raw, team2Score: g1b_raw, isComplete: complete))
            if complete {
                if g1a_raw > g1b_raw { score1 += 1 } else { score2 += 1 }
            }
        }
        
        // Set 2 (only if setsToWin > 1)
        if setsToWin > 1 && (g2a_raw > 0 || g2b_raw > 0) {
            let complete = isSetComplete(g2a_raw, g2b_raw, target: pointsPerSet, cap: pointCap)
            setHistory.append(SetScore(setNumber: 2, team1Score: g2a_raw, team2Score: g2b_raw, isComplete: complete))
            if complete {
                if g2a_raw > g2b_raw { score1 += 1 } else { score2 += 1 }
            }
        }
        
        // Set 3 (only for best-of-3, and use 15 for 3rd set typically)
        if setsToWin >= 2 && (g3a_raw > 0 || g3b_raw > 0) {
            let limit = 15 // Usually 15 for 3rd set
            let complete = isSetComplete(g3a_raw, g3b_raw, target: limit, cap: nil)
            setHistory.append(SetScore(setNumber: 3, team1Score: g3a_raw, team2Score: g3b_raw, isComplete: complete))
            if complete {
                if g3a_raw > g3b_raw { score1 += 1 } else { score2 += 1 }
            }
        }
        
        // Calculate current set number
        let setNum = setHistory.count + (setHistory.last?.isComplete == true ? 1 : 0)
        if setHistory.isEmpty && (g1a_raw > 0 || g1b_raw > 0) {
             // Currently in set 1
        }
        
        // Determine status - use actual setsToWin
        let won1 = score1 >= setsToWin
        let won2 = score2 >= setsToWin
        
        let status: String
        if won1 || won2 {
            status = "Final"
        } else if !setHistory.isEmpty || g1a_raw > 0 || g1b_raw > 0 {
            status = "In Progress"
        } else {
            status = "Pre-Match"
        }
        
        return ScoreSnapshot(
            courtId: courtId,
            matchId: nil,
            status: status,
            setNumber: setNum,
            team1Name: name1,
            team2Name: name2,
            team1Seed: currentMatch?.team1Seed,
            team2Seed: currentMatch?.team2Seed,
            team1Score: score1,
            team2Score: score2,
            serve: nil,
            setHistory: setHistory,
            timestamp: Date(),
            setsToWin: setsToWin
        )
    }
    
    private func normalizeDictFormat(_ dict: [String: Any], courtId: Int, currentMatch: MatchItem?) -> ScoreSnapshot {
        let score = dict["score"] as? [String: Any]
        let home = score?["home"] as? Int ?? 0
        let away = score?["away"] as? Int ?? 0
        
        let name1 = (dict["team1_text"] as? String) ?? (dict["homeTeam"] as? String) ?? (dict["team1Name"] as? String) ?? "Team A"
        let name2 = (dict["team2_text"] as? String) ?? (dict["awayTeam"] as? String) ?? (dict["team2Name"] as? String) ?? "Team B"
        
        let statusStr = (dict["status"] as? String) ?? "Pre-Match"
        let setNum = (dict["setNumber"] as? Int) ?? 1
        let setsToWin = currentMatch?.setsToWin ?? 2
        
        return ScoreSnapshot(
            courtId: courtId,
            matchId: dict["matchId"] as? Int,
            status: statusStr,
            setNumber: setNum,
            team1Name: name1,
            team2Name: name2,
            team1Seed: currentMatch?.team1Seed,
            team2Seed: currentMatch?.team2Seed,
            team1Score: home,
            team2Score: away,
            serve: dict["serve"] as? String,
            setHistory: [],
            timestamp: Date(),
            setsToWin: setsToWin
        )
    }
    
    // MARK: - Configuration Persistence
    
    private var configURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("MultiCourtScore")
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        return appFolder.appendingPathComponent("courts_config.json")
    }
    
    private func loadConfiguration() {
        guard FileManager.default.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              let loaded = try? JSONDecoder().decode([Court].self, from: data) else {
            return
        }
        courts = loaded
        print("📂 Loaded configuration with \(courts.count) courts")
    }
    
    private func saveConfiguration() {
        guard let data = try? JSONEncoder().encode(courts) else { return }
        try? data.write(to: configURL)
    }
    
    private func ensureAllCourtsExist() {
        for i in 1...AppConfig.maxCourts {
            if !courts.contains(where: { $0.id == i }) {
                courts.append(Court.create(id: i))
            }
        }
        courts.sort { $0.id < $1.id }
    }
}

// MARK: - Score Cache

actor ScoreCache {
    private var cache: [URL: (data: Data, timestamp: Date)] = [:]
    
    func get(_ url: URL) async throws -> Data {
        if let cached = cache[url], 
           cached.timestamp.timeIntervalSinceNow > -NetworkConstants.cacheExpiration {
            return cached.data
        }
        
        // Force bypass of URLCache to ensure real-time data
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        
        let (data, _) = try await URLSession.shared.data(for: request)
        cache[url] = (data, Date())
        return data
    }
    
    func invalidate(_ url: URL) {
        cache.removeValue(forKey: url)
    }
    
    func clearAll() {
        cache.removeAll()
    }
}
