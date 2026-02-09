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
    @Published var appSettings = ConfigStore().loadSettings()
    
    // MARK: - Services
    private let webSocketHub: WebSocketHub
    private let configStore: ConfigStore
    private let apiClient: APIClient
    private let scoreCache: ScoreCache
    
    // MARK: - Private State
    private var pollingTimers: [Int: Timer] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var lastQueueRefreshTimes: [Int: Date] = [:]
    private var lastCourtChangeCheck: Date = .distantPast
    
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
            await webSocketHub.start(with: self, port: appSettings.serverPort)
            print("🚀 MultiCourtScore v2 services started on port \(appSettings.serverPort)")
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
        let interval = appSettings.pollingInterval + Double((courtId * 97) % 800) / 1000.0
        
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
        return "http://localhost:\(appSettings.serverPort)/overlay/court/\(courtId)/?theme=\(appSettings.overlayTheme)"
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
            
            // Smart Queue Switch: If current match is 0-0 but another has scoring, switch to it.
            // If we switch, stop processing this stale snapshot.
            let switchedToDifferentMatch = await checkForSmartQueueSwitch(courtId: courtId, currentSnapshot: snapshot)
            if switchedToDifferentMatch {
                return
            }
            
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
                        courts[idx].lastSnapshot = nil
                        courts[idx].status = .waiting
                        courts[idx].liveSince = nil
                        courts[idx].finishedAt = nil  // Reset for next match
                        lastScoreChangeTime[courtId] = nil
                        print("⏭️ Auto-advanced court \(courtId) to match \(nextIndex + 1)")
                        
                        // Trigger immediate metadata refresh for the new sequence
                        await refreshQueueMetadata(for: courtId)
                        lastQueueRefreshTimes[courtId] = Date()
                    }
                }
            } else {
                courts[idx].status = newStatus
                courts[idx].lastSnapshot = snapshot
                courts[idx].finishedAt = nil  // Clear if match is not final
            }
            
            
            // Periodically refresh metadata for ALL matches including current (every 15s)
            let lastRefresh = lastQueueRefreshTimes[courtId] ?? Date.distantPast
            if Date().timeIntervalSince(lastRefresh) > 15 {
                // Update current match team names if they've changed (e.g., "Match 1 Winner" → actual names)
                if snapshot.team1Name != matchItem.team1Name || snapshot.team2Name != matchItem.team2Name {
                    print("🔄 Updated current match team names: \(snapshot.team1Name) vs \(snapshot.team2Name)")
                    courts[idx].queue[activeIdx].team1Name = snapshot.team1Name
                    courts[idx].queue[activeIdx].team2Name = snapshot.team2Name
                }
                
                // Update queued matches
                await refreshQueueMetadata(for: courtId)
                lastQueueRefreshTimes[courtId] = Date()
            }
            
            // Periodically check for court reassignments (every 60s)
            if Date().timeIntervalSince(lastCourtChangeCheck) > 60 {
                await checkForCourtChanges()
                lastCourtChangeCheck = Date()
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
    
    /// Smart Queue Switch: Check if current match is 0-0 but another queue match has active scoring.
    /// If so, auto-switch to the active match to prioritize live content.
    private func checkForSmartQueueSwitch(courtId: Int, currentSnapshot: ScoreSnapshot) async -> Bool {
        guard let idx = courtIndex(for: courtId) else { return false }
        guard let activeIdx = courts[idx].activeIndex else { return false }
        
        // Only smart-switch if current match hasn't started (0-0)
        let currentScore = currentSnapshot.team1Score + currentSnapshot.team2Score
        guard currentScore == 0 else { return false }
        
        // Don't switch if we've been live on this match (liveSince set)
        if courts[idx].liveSince != nil { return false }
        
        // Scan queue for any match with active scoring
        for (queueIdx, match) in courts[idx].queue.enumerated() {
            guard queueIdx != activeIdx else { continue } // Skip current
            
            do {
                let data = try await apiClient.fetchData(from: match.apiURL)
                let snapshot = normalizeData(data, courtId: 0, currentMatch: match)
                
                // Check if this match has active scoring (not finished, not 0-0)
                let score = snapshot.team1Score + snapshot.team2Score
                if score > 0 && !snapshot.isFinal {
                    print("🔄 Smart Queue Switch: Found active match at index \(queueIdx) with score \(score). Switching from 0-0 match at index \(activeIdx)")
                    courts[idx].activeIndex = queueIdx
                    courts[idx].lastSnapshot = nil
                    courts[idx].status = .waiting
                    return true // Only switch to first found active match
                }
            } catch {
                // Ignore errors, just skip this match
                continue
            }
        }
        
        return false
    }
    
    // Refresh TBD names in the queue
    private func refreshQueueMetadata(for courtId: Int) async {
        guard let idx = courtIndex(for: courtId) else { return }

        // Capture queue count at start to avoid race conditions
        let queueCount = courts[idx].queue.count
        let startIndex = (courts[idx].activeIndex ?? -1) + 1
        guard startIndex < queueCount else { return }

            for i in startIndex..<queueCount {
                // Re-validate index before each access (queue may have changed)
                guard let courtIdx = courtIndex(for: courtId),
                      i < courts[courtIdx].queue.count else {
                    print("⚠️ Queue changed during metadata refresh, stopping early")
                    return
                }

                let match = courts[courtIdx].queue[i]

                do {
                    // Fetch fresh data for the queued match
                    let data = try await apiClient.fetchData(from: match.apiURL)
                    let snapshot = normalizeData(data, courtId: 0, currentMatch: match)

                    // Re-validate again before write
                    guard let writeIdx = courtIndex(for: courtId),
                          i < courts[writeIdx].queue.count else {
                        print("⚠️ Queue changed during metadata refresh, stopping early")
                        return
                    }
                    
                    var hasChanges = false
                    let oldMatch = courts[writeIdx].queue[i]

                    // Update Names
                    if snapshot.team1Name != match.team1Name {
                        ChangeLogService.shared.logChange(courtId: courtId, match: match, field: "Team 1", old: match.team1Name ?? "", new: snapshot.team1Name)
                        courts[writeIdx].queue[i].team1Name = snapshot.team1Name
                        hasChanges = true
                    }
                    if snapshot.team2Name != match.team2Name {
                        ChangeLogService.shared.logChange(courtId: courtId, match: match, field: "Team 2", old: match.team2Name ?? "", new: snapshot.team2Name)
                        courts[writeIdx].queue[i].team2Name = snapshot.team2Name
                        hasChanges = true
                    }
                    
                    // Update Time
                    if let newTime = snapshot.scheduledTime, newTime != match.scheduledTime {
                        ChangeLogService.shared.logChange(courtId: courtId, match: match, field: "Time", old: match.scheduledTime ?? "", new: newTime)
                        courts[writeIdx].queue[i].scheduledTime = newTime
                        hasChanges = true
                    }
                    
                    // Update Match Number
                    if let newMatchNum = snapshot.matchNumber, newMatchNum != match.matchNumber {
                        ChangeLogService.shared.logChange(courtId: courtId, match: match, field: "Match #", old: match.matchNumber ?? "", new: newMatchNum)
                        courts[writeIdx].queue[i].matchNumber = newMatchNum
                        hasChanges = true
                    }
                    
                    // Update Court Number
                    if let newCourt = snapshot.courtNumber, newCourt != match.courtNumber {
                        ChangeLogService.shared.logChange(courtId: courtId, match: match, field: "Court", old: match.courtNumber ?? "", new: newCourt)
                        courts[writeIdx].queue[i].courtNumber = newCourt
                        hasChanges = true
                    }
                    
                    // Update Seeds
                    if let newSeed1 = snapshot.team1Seed, newSeed1 != match.team1Seed {
                        ChangeLogService.shared.logChange(courtId: courtId, match: match, field: "Seed 1", old: match.team1Seed ?? "", new: newSeed1)
                        courts[writeIdx].queue[i].team1Seed = newSeed1
                        hasChanges = true
                    }
                    if let newSeed2 = snapshot.team2Seed, newSeed2 != match.team2Seed {
                        ChangeLogService.shared.logChange(courtId: courtId, match: match, field: "Seed 2", old: match.team2Seed ?? "", new: newSeed2)
                        courts[writeIdx].queue[i].team2Seed = newSeed2
                        hasChanges = true
                    }
                    
                    if hasChanges {
                        print("✅ Updated queue metadata for match \(i)")
                    }
                } catch {
                    print("⚠️ Failed to refresh queue metadata: \(error.localizedDescription)")
                }
            }
        }
    
    // MARK: - Court Change Detection (60-second polling)
    
    /// Check all queued matches for court reassignments and move them to correct camera queues
    private func checkForCourtChanges() async {
        let mappingStore = CourtMappingStore.shared
        var changesToProcess: [(matchId: UUID, fromCourt: Int, toCourt: Int, match: MatchItem)] = []
        
        // Scan all courts for matches with changed court assignments
        for courtIdx in courts.indices {
            for matchIdx in courts[courtIdx].queue.indices {
                let match = courts[courtIdx].queue[matchIdx]
                guard let physicalCourt = match.physicalCourt else { continue }
                
                // Check if this match should be on a different camera based on current mapping
                if let correctCameraId = mappingStore.cameraId(for: physicalCourt) {
                    let currentCameraId = courts[courtIdx].id
                    
                    if correctCameraId != currentCameraId {
                        // This match needs to move!
                        changesToProcess.append((
                            matchId: match.id,
                            fromCourt: currentCameraId,
                            toCourt: correctCameraId,
                            match: match
                        ))
                    }
                }
            }
        }
        
        // Process court changes
        for change in changesToProcess {
            await processCourtChange(change)
        }
    }
    
    private func processCourtChange(_ change: (matchId: UUID, fromCourt: Int, toCourt: Int, match: MatchItem)) async {
        guard let fromIdx = courtIndex(for: change.fromCourt),
              let toIdx = courtIndex(for: change.toCourt),
              let removedIndex = courts[fromIdx].queue.firstIndex(where: { $0.id == change.matchId }) else { return }
        
        let wasLiveMatch = {
            guard courts[fromIdx].status == .live,
                  let active = courts[fromIdx].activeIndex,
                  active < courts[fromIdx].queue.count else {
                return false
            }
            return courts[fromIdx].queue[active].id == change.matchId
        }()
        
        // Remove from source queue at exact index so active index tracking stays correct.
        courts[fromIdx].queue.remove(at: removedIndex)
        
        // Adjust source activeIndex if removal happened before or at active position.
        if let active = courts[fromIdx].activeIndex {
            if courts[fromIdx].queue.isEmpty {
                courts[fromIdx].activeIndex = nil
            } else if active > removedIndex {
                courts[fromIdx].activeIndex = active - 1
            } else if active >= courts[fromIdx].queue.count {
                courts[fromIdx].activeIndex = courts[fromIdx].queue.count - 1
            }
        }
        
        if wasLiveMatch {
            courts[fromIdx].status = courts[fromIdx].queue.isEmpty ? .idle : .waiting
            courts[fromIdx].liveSince = nil
            courts[fromIdx].lastSnapshot = nil
            courts[fromIdx].finishedAt = nil
        }
        
        // Check if target camera has a live match
        let targetIsLive = courts[toIdx].status == .live
        
        // Insert into target queue in proper order (by scheduledTime, then matchNumber)
        var insertIndex = targetIsLive ? ((courts[toIdx].activeIndex ?? 0) + 1) : 0
        
        // Find correct position based on scheduled time
        for i in insertIndex..<courts[toIdx].queue.count {
            if compareMatchOrder(change.match, courts[toIdx].queue[i]) {
                insertIndex = i
                break
            }
            insertIndex = i + 1
        }
        
        courts[toIdx].queue.insert(change.match, at: min(insertIndex, courts[toIdx].queue.count))
        
        // Log the change
        let matchLabel = change.match.displayName
        print("🔄 Court change: \(matchLabel) moved from \(CourtNaming.displayName(for: change.fromCourt)) to \(CourtNaming.displayName(for: change.toCourt))")
        
        // Send notification
        let event = CourtChangeEvent(
            matchLabel: matchLabel,
            oldCourt: CourtNaming.displayName(for: change.fromCourt),
            newCourt: CourtNaming.displayName(for: change.toCourt),
            oldCamera: change.fromCourt,
            newCamera: change.toCourt,
            isLiveMatch: wasLiveMatch,
            timestamp: Date()
        )
        
        await NotificationService.shared.sendCourtChangeAlert(event)
    }
    
    /// Compare two matches for ordering: returns true if match1 should come before match2
    private func compareMatchOrder(_ match1: MatchItem, _ match2: MatchItem) -> Bool {
        // First compare by scheduled time
        if let time1 = match1.scheduledTime, let time2 = match2.scheduledTime {
            let comparison = compareTimeStrings(time1, time2)
            if comparison != 0 {
                return comparison < 0
            }
        }
        
        // Then by match number
        if let num1 = extractMatchNumber(from: match1.matchNumber),
           let num2 = extractMatchNumber(from: match2.matchNumber) {
            return num1 < num2
        }
        
        return false
    }
    
    private func compareTimeStrings(_ a: String, _ b: String) -> Int {
        let pattern = #"(\d{1,2}):(\d{2})\s*(AM|PM)"#
        guard let regexA = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let regexB = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let matchA = regexA.firstMatch(in: a, range: NSRange(a.startIndex..., in: a)),
              let matchB = regexB.firstMatch(in: b, range: NSRange(b.startIndex..., in: b)) else {
            return 0
        }
        
        let hourA = Int((a as NSString).substring(with: matchA.range(at: 1))) ?? 0
        let minA = Int((a as NSString).substring(with: matchA.range(at: 2))) ?? 0
        let ampmA = (a as NSString).substring(with: matchA.range(at: 3)).uppercased()
        
        let hourB = Int((b as NSString).substring(with: matchB.range(at: 1))) ?? 0
        let minB = Int((b as NSString).substring(with: matchB.range(at: 2))) ?? 0
        let ampmB = (b as NSString).substring(with: matchB.range(at: 3)).uppercased()
        
        let hour24A = (ampmA == "PM" && hourA != 12 ? hourA + 12 : (ampmA == "AM" && hourA == 12 ? 0 : hourA))
        let hour24B = (ampmB == "PM" && hourB != 12 ? hourB + 12 : (ampmB == "AM" && hourB == 12 ? 0 : hourB))
        
        if hour24A != hour24B { return hour24A - hour24B }
        return minA - minB
    }
    
    private func extractMatchNumber(from matchNumber: String?) -> Int? {
        guard let num = matchNumber else { return nil }
        let digits = num.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return Int(digits)
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
        
        // Extract team names with fallback chain:
        // 1. 'players' field (sometimes contains placeholder text)
        // 2. 'teamName' field (actual team names when assigned)
        // 3. currentMatch team names (preserves scraped placeholders like "Match 1 Winner")
        // 4. "TBD" as final fallback
        let name1 = (t1["players"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty() ??
                    (t1["teamName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty() ??
                    currentMatch?.team1Name ??
                    "TBD"
        let name2 = (t2["players"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty() ??
                    (t2["teamName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty() ??
                    currentMatch?.team2Name ??
                    "TBD"
        
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
            team1Seed: (t1["seed"] as? String) ?? currentMatch?.team1Seed,
            team2Seed: (t2["seed"] as? String) ?? currentMatch?.team2Seed,
            scheduledTime: (array[0]["time"] as? String) ?? currentMatch?.scheduledTime,
            matchNumber: (array[0]["match"] as? String) ?? currentMatch?.matchNumber,
            courtNumber: (array[0]["court"] as? String) ?? currentMatch?.courtNumber,
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
            team1Seed: (dict["seed1"] as? String) ?? currentMatch?.team1Seed,
            team2Seed: (dict["seed2"] as? String) ?? currentMatch?.team2Seed,
            scheduledTime: (dict["time"] as? String) ?? currentMatch?.scheduledTime,
            matchNumber: (dict["matchNumber"] as? String) ?? currentMatch?.matchNumber,
            courtNumber: (dict["court"] as? String) ?? currentMatch?.courtNumber,
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

// MARK: - String Extension

extension String {
    /// Returns nil if the string is empty, otherwise returns self
    func nilIfEmpty() -> String? {
        return self.isEmpty ? nil : self
    }
}
