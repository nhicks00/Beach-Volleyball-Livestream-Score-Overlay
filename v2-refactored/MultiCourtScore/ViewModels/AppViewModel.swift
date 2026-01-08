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
        webSocketHub.start(with: self, port: NetworkConstants.webSocketPort)
        print("🚀 MultiCourtScore v2 services started")
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
    
    func replaceQueue(_ courtId: Int, with items: [MatchItem]) {
        guard let idx = courtIndex(for: courtId) else { return }
        courts[idx].queue = items
        courts[idx].activeIndex = items.isEmpty ? nil : 0
        courts[idx].status = items.isEmpty ? .idle : .waiting
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
        for court in courts where !court.queue.isEmpty {
            startPolling(for: court.id)
        }
    }
    
    func stopAllPolling() {
        for courtId in pollingTimers.keys {
            stopPolling(for: courtId)
        }
    }
    
    // MARK: - Navigation
    
    func skipToNext(_ courtId: Int) {
        guard let idx = courtIndex(for: courtId) else { return }
        guard let activeIdx = courts[idx].activeIndex else { return }
        
        let nextIndex = activeIdx + 1
        if nextIndex < courts[idx].queue.count {
            courts[idx].activeIndex = nextIndex
            courts[idx].status = .waiting
            courts[idx].liveSince = nil
            courts[idx].lastSnapshot = nil
            saveConfiguration()
        }
    }
    
    func skipToPrevious(_ courtId: Int) {
        guard let idx = courtIndex(for: courtId) else { return }
        guard let activeIdx = courts[idx].activeIndex, activeIdx > 0 else { return }
        
        courts[idx].activeIndex = activeIdx - 1
        courts[idx].status = .waiting
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
            let snapshot = normalizeData(data, courtId: courtId)
            
            let previousStatus = courts[idx].status
            let newStatus = determineStatus(from: snapshot)
            
            // Update stopwatch
            if previousStatus != .live && newStatus == .live {
                courts[idx].liveSince = Date()
            }
            if newStatus != .live {
                courts[idx].liveSince = nil
            }
            
            // Handle match completion - auto-advance
            if snapshot.isFinal {
                courts[idx].status = .finished
                courts[idx].lastSnapshot = snapshot
                
                // Auto-advance after 3 minutes
                let nextIndex = activeIdx + 1
                if nextIndex < courts[idx].queue.count {
                    // Check if next match has started
                    if await nextMatchHasStarted(courts[idx].queue[nextIndex]) {
                        courts[idx].activeIndex = nextIndex
                        courts[idx].status = .waiting
                        courts[idx].liveSince = nil
                    }
                }
            } else {
                courts[idx].status = newStatus
                courts[idx].lastSnapshot = snapshot
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
            let data = try await apiClient.fetchData(from: match.apiURL)
            let snapshot = normalizeData(data, courtId: 0)
            return snapshot.hasStarted
        } catch {
            return false
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
    
    private func normalizeData(_ data: Data, courtId: Int) -> ScoreSnapshot {
        guard let jsonObj = try? JSONSerialization.jsonObject(with: data) else {
            return .empty(courtId: courtId)
        }
        
        // Handle vMix array format
        if let array = jsonObj as? [[String: Any]] {
            return normalizeArrayFormat(array, courtId: courtId)
        }
        
        // Handle dictionary format
        if let dict = jsonObj as? [String: Any] {
            return normalizeDictFormat(dict, courtId: courtId)
        }
        
        return .empty(courtId: courtId)
    }
    
    private func normalizeArrayFormat(_ array: [[String: Any]], courtId: Int) -> ScoreSnapshot {
        guard array.count >= 2 else { return .empty(courtId: courtId) }
        
        let t1 = array[0]
        let t2 = array[1]
        
        let name1 = (t1["teamName"] as? String) ?? "Team A"
        let name2 = (t2["teamName"] as? String) ?? "Team B"
        let score1 = (t1["score"] as? Int) ?? 0
        let score2 = (t2["score"] as? Int) ?? 0
        let setNum = (t1["setNumber"] as? Int) ?? 1
        let won1 = (t1["won"] as? Bool) ?? false
        let won2 = (t2["won"] as? Bool) ?? false
        
        let g1a = (t1["game1Score"] as? Int) ?? 0
        let g1b = (t2["game1Score"] as? Int) ?? 0
        let g2a = (t1["game2Score"] as? Int) ?? 0
        let g2b = (t2["game2Score"] as? Int) ?? 0
        
        var setHistory: [SetScore] = []
        if g1a > 0 || g1b > 0 {
            setHistory.append(SetScore(setNumber: 1, team1Score: g1a, team2Score: g1b, isComplete: setNum > 1))
        }
        if g2a > 0 || g2b > 0 {
            setHistory.append(SetScore(setNumber: 2, team1Score: g2a, team2Score: g2b, isComplete: setNum > 2))
        }
        
        let status: String
        if won1 || won2 {
            status = "Final"
        } else if score1 > 0 || score2 > 0 || setNum > 1 {
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
            team1Score: score1,
            team2Score: score2,
            serve: nil,
            setHistory: setHistory,
            timestamp: Date()
        )
    }
    
    private func normalizeDictFormat(_ dict: [String: Any], courtId: Int) -> ScoreSnapshot {
        let score = dict["score"] as? [String: Any]
        let home = score?["home"] as? Int ?? 0
        let away = score?["away"] as? Int ?? 0
        
        let name1 = (dict["homeTeam"] as? String) ?? (dict["team1Name"] as? String) ?? "Team A"
        let name2 = (dict["awayTeam"] as? String) ?? (dict["team2Name"] as? String) ?? "Team B"
        
        let statusStr = (dict["status"] as? String) ?? "Pre-Match"
        let setNum = (dict["setNumber"] as? Int) ?? 1
        
        return ScoreSnapshot(
            courtId: courtId,
            matchId: dict["matchId"] as? Int,
            status: statusStr,
            setNumber: setNum,
            team1Name: name1,
            team2Name: name2,
            team1Score: home,
            team2Score: away,
            serve: dict["serve"] as? String,
            setHistory: [],
            timestamp: Date()
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

class ScoreCache {
    private var cache: [URL: (data: Data, timestamp: Date)] = [:]
    private let lock = NSLock()
    
    func get(_ url: URL) async throws -> Data {
        lock.lock()
        if let cached = cache[url], 
           cached.timestamp.timeIntervalSinceNow > -NetworkConstants.cacheExpiration {
            lock.unlock()
            return cached.data
        }
        lock.unlock()
        
        let (data, _) = try await URLSession.shared.data(from: url)
        
        lock.lock()
        cache[url] = (data, Date())
        lock.unlock()
        
        return data
    }
    
    func invalidate(_ url: URL) {
        lock.lock()
        cache.removeValue(forKey: url)
        lock.unlock()
    }
    
    func clearAll() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}
