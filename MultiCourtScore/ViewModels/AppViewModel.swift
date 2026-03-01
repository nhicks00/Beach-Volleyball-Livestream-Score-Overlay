//
//  AppViewModel.swift
//  MultiCourtScore v2
//
//  Main application view model with improved state management
//

import Foundation
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    // MARK: - Published State
    @Published private(set) var courts: [Court] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: AppError?
    @Published private(set) var serverRunning = false
    @Published var scannerViewModel = ScannerViewModel()
    @Published var appSettings: ConfigStore.AppSettings = ConfigStore.AppSettings()
    
    // MARK: - Services
    private let webSocketHub: WebSocketHub
    private let configStore: ConfigStore
    private let apiClient: APIClient
    private let scoreCache: ScoreCache
    
    // MARK: - Private State
    private var pollingTimers: [Int: Timer] = [:]
    private var lastQueueRefreshTimes: [Int: Date] = [:]
    private var lastCourtChangeCheck: Date = .distantPast
    private var pollsInFlight: Set<Int> = []
    private var saveTask: Task<Void, Never>?
    private var watchdogTimer: Timer?
    private var lastSmartSwitchCheck: [Int: Date] = [:]

    // Inactivity tracking
    private var lastScoreSnapshot: [Int: (pts1: Int, pts2: Int, s1: Int, s2: Int)] = [:]
    private var lastScoreChangeTime: [Int: Date] = [:]
    // Per-court flag indicating we observed non-final live scoring for current active match.
    private var observedActiveScoring: [Int: Bool] = [:]
    // Server-side serve tracking: infer serving team from score changes
    private var lastServeTeam: [Int: String] = [:]
    
    // MARK: - Initialization
    
    init() {
        self.webSocketHub = WebSocketHub.shared
        self.configStore = ConfigStore()
        self.apiClient = APIClient()
        self.scoreCache = ScoreCache(apiClient: apiClient)
        self.appSettings = configStore.loadSettings()
        
        loadConfiguration()
        ensureAllCourtsExist()
    }
    
    // MARK: - Services Lifecycle

    func startServices() {
        Task {
            await webSocketHub.start(with: self, port: appSettings.serverPort)
            serverRunning = webSocketHub.isRunning
            print("🚀 MultiCourtScore v2 services started on port \(appSettings.serverPort)")
        }
        startWatchdog()
    }

    func stopServices() {
        stopAllPolling()
        stopWatchdog()
        webSocketHub.stop()
        serverRunning = false
        saveConfigurationNow()
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
        saveConfigurationNow()
    }

    func setScoreboardLayout(_ courtId: Int, layout: String?) {
        guard let idx = courtIndex(for: courtId) else { return }
        courts[idx].scoreboardLayout = layout
        saveConfigurationNow()
    }
    
    func replaceQueue(_ courtId: Int, with items: [MatchItem], startIndex: Int? = 0) {
        guard let idx = courtIndex(for: courtId) else { return }
        courts[idx].queue = items.map(normalizeLegacyPoolFormat)
        courts[idx].activeIndex = items.isEmpty ? nil : (startIndex ?? 0)
        courts[idx].status = .idle  // Require manual start - don't auto-set to waiting
        courts[idx].lastSnapshot = nil
        courts[idx].liveSince = nil
        courts[idx].finishedAt = nil
        observedActiveScoring[courtId] = false
        saveConfigurationNow()
    }

    func appendToQueue(_ courtId: Int, items: [MatchItem]) {
        guard let idx = courtIndex(for: courtId) else { return }
        courts[idx].queue.append(contentsOf: items.map(normalizeLegacyPoolFormat))
        if courts[idx].activeIndex == nil && !items.isEmpty {
            courts[idx].activeIndex = 0
        }
        saveConfigurationNow()
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
        saveConfigurationNow()
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
        // Idempotent start: avoid resetting live courts back to warmup on repeated Start All clicks.
        if pollingTimers[courtId] != nil {
            courts[idx].errorMessage = nil
            return
        }
        if !courts[idx].status.isPolling {
            courts[idx].status = .waiting
            courts[idx].liveSince = nil
        }
        observedActiveScoring[courtId] = false
        courts[idx].errorMessage = nil
        
        // Staggered polling with small jitter to avoid thundering herd
        let jitter = Double((courtId * 317) % 400) / 1000.0
        let interval = appSettings.pollingInterval + Double((courtId * 97) % 300) / 1000.0
        
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(jitter * 1_000_000_000))
                await self?.pollOnce(courtId)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollingTimers[courtId] = timer
        
        // Kick an immediate cycle so completed queues don't appear stuck in warmup.
        Task { @MainActor in
            await self.advanceToFirstPlayableMatchIfNeeded(courtId: courtId)
            await self.pollOnce(courtId)
        }
        
        saveConfigurationNow()
        print("▶️ Started polling for court \(courtId)")
    }
    
    func stopPolling(for courtId: Int) {
        pollingTimers[courtId]?.invalidate()
        pollingTimers[courtId] = nil
        pollsInFlight.remove(courtId)
        observedActiveScoring.removeValue(forKey: courtId)
        lastScoreChangeTime.removeValue(forKey: courtId)
        lastScoreSnapshot.removeValue(forKey: courtId)
        
        if let idx = courtIndex(for: courtId) {
            courts[idx].status = .idle
            courts[idx].liveSince = nil
        }
        scheduleSave()
        print("⏹️ Stopped polling for court \(courtId)")
    }
    
    func startAllPolling() {
        // Ensure services are running
        if !webSocketHub.isRunning {
             startServices()
        }

        for court in courts where !court.queue.isEmpty {
            if pollingTimers[court.id] == nil {
                startPolling(for: court.id)
            }
        }
    }
    
    func stopAllPolling() {
        // Stop all active timers
        for courtId in Array(pollingTimers.keys) {
            stopPolling(for: courtId)
        }
        
        // Also reset status for any court with a queue (in case timer wasn't created yet)
        for idx in courts.indices where !courts[idx].queue.isEmpty {
            if courts[idx].status != .idle {
                courts[idx].status = .idle
                courts[idx].liveSince = nil
            }
        }
        saveConfigurationNow()
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
            observedActiveScoring[courtId] = false
            saveConfigurationNow()
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
        observedActiveScoring[courtId] = false
        saveConfigurationNow()
    }

    // MARK: - Overlay URL
    
    func overlayURL(for courtId: Int) -> String {
        return "http://localhost:\(appSettings.serverPort)/overlay/court/\(courtId)/"
    }
    
    // MARK: - Watchdog

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPollingHealth() }
        }
        if let t = watchdogTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func checkPollingHealth() {
        for court in courts where court.status.isPolling {
            if let lastPoll = court.lastPollTime, Date().timeIntervalSince(lastPoll) > 30 {
                print("🚨 WATCHDOG: Court \(court.id) stale — restarting")
                pollingTimers[court.id]?.invalidate()
                pollingTimers[court.id] = nil
                pollsInFlight.remove(court.id)
                startPolling(for: court.id)
            }
        }
    }

    // MARK: - Private Methods
    
    private func pollOnce(_ courtId: Int) async {
        guard let idx = courtIndex(for: courtId),
              courts[idx].status != .idle else {
            stopPolling(for: courtId)
            return
        }

        // Prevent overlapping poll cycles for the same court when network calls run long.
        guard !pollsInFlight.contains(courtId) else { return }
        pollsInFlight.insert(courtId)
        defer { pollsInFlight.remove(courtId) }
        
        guard let activeIdx = courts[idx].activeIndex,
              activeIdx < courts[idx].queue.count else {
            return
        }
        
        let matchItem = courts[idx].queue[activeIdx]
        
        do {
            let data = try await scoreCache.get(matchItem.apiURL)
            // Pass matchItem to normalizeData to access seeds
            var snapshot = normalizeData(data, courtId: courtId, currentMatch: matchItem)

            // Apply server-side serve tracking (vMix doesn't provide serve info)
            if let serve = lastServeTeam[courtId], snapshot.serve == nil {
                snapshot.serve = serve
            }
            
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
                // Infer serving team from point changes
                if let prev = prevData {
                    if currentP1 > prev.pts1 {
                        lastServeTeam[courtId] = "home"
                    } else if currentP2 > prev.pts2 {
                        lastServeTeam[courtId] = "away"
                    }
                }
                // Point or set changed: update tracker
                lastScoreSnapshot[courtId] = (pts1: currentP1, pts2: currentP2, s1: currentS1, s2: currentS2)
                lastScoreChangeTime[courtId] = Date()
            }
            
            let timeSinceLastScore = Date().timeIntervalSince(lastScoreChangeTime[courtId] ?? Date())
            let isStale = timeSinceLastScore >= appSettings.staleMatchTimeout
            
            let previousStatus = courts[idx].status
            let matchConcluded = isMatchConcluded(snapshot: snapshot, for: matchItem)
            let newStatus = determineStatus(from: snapshot, matchConcluded: matchConcluded)
            if newStatus == .live && !matchConcluded {
                observedActiveScoring[courtId] = true
            }
            
            // Update stopwatch
            if previousStatus != .live && newStatus == .live {
                courts[idx].liveSince = Date()
            }
            if newStatus != .live {
                courts[idx].liveSince = nil
            }
            
            // Handle match completion OR Stale timeout
            if matchConcluded || isStale {
                if isStale && !matchConcluded {
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
                    let holdDuration = appSettings.holdScoreDuration
                    let timeSinceFinish = Date().timeIntervalSince(courts[idx].finishedAt ?? Date())
                    
                    // Advance if stale, or if this is startup/backlog final data, or when hold conditions are met.
                    let holdExpired = timeSinceFinish >= holdDuration
                    // Keep post-match hold only when this match was observed as actively scoring.
                    let shouldHoldPostMatch = matchConcluded
                        && (observedActiveScoring[courtId] ?? false)
                        && (previousStatus == .live || (previousStatus == .finished && !holdExpired))
                    let nextStarted = shouldHoldPostMatch ? await nextMatchHasStarted(courts[idx].queue[nextIndex]) : true
                    let shouldAdvance = isStale || (!shouldHoldPostMatch) || holdExpired || nextStarted
                    
                    if shouldAdvance {
                        // Skip over any consecutive already-final matches so we land on the first playable match.
                        let targetIndex = await firstNonFinalQueueIndex(courtId: courtId, startingAt: nextIndex)

                        guard let writeIdx = courtIndex(for: courtId),
                              targetIndex < courts[writeIdx].queue.count else {
                            return
                        }

                        courts[writeIdx].activeIndex = targetIndex
                        courts[writeIdx].lastSnapshot = nil
                        courts[writeIdx].status = .waiting
                        courts[writeIdx].liveSince = nil
                        courts[writeIdx].finishedAt = nil  // Reset for next match
                        observedActiveScoring[courtId] = false
                        lastScoreChangeTime[courtId] = nil
                        lastScoreSnapshot[courtId] = nil

                        let skippedCompleted = max(0, targetIndex - nextIndex)
                        if skippedCompleted > 0 {
                            print("⏭️ Auto-advanced court \(courtId) to match \(targetIndex + 1), skipped \(skippedCompleted) completed match(es)")
                        } else {
                            print("⏭️ Auto-advanced court \(courtId) to match \(targetIndex + 1)")
                        }
                        
                        // Trigger immediate metadata refresh for the new sequence
                        await refreshQueueMetadata(for: courtId)
                        lastQueueRefreshTimes[courtId] = Date()
                        scheduleSave()
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
                if let writeIdx = courtIndex(for: courtId),
                   let writeActive = courts[writeIdx].activeIndex,
                   writeActive < courts[writeIdx].queue.count,
                   courts[writeIdx].queue[writeActive].id == matchItem.id,
                   (snapshot.team1Name != courts[writeIdx].queue[writeActive].team1Name
                    || snapshot.team2Name != courts[writeIdx].queue[writeActive].team2Name) {
                    print("🔄 Updated current match team names: \(snapshot.team1Name) vs \(snapshot.team2Name)")
                    courts[writeIdx].queue[writeActive].team1Name = snapshot.team1Name
                    courts[writeIdx].queue[writeActive].team2Name = snapshot.team2Name
                    scheduleSave()
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

            if let writeIdx = courtIndex(for: courtId) {
                courts[writeIdx].lastPollTime = Date()
                courts[writeIdx].errorMessage = nil
            }
            // Only save if meaningful state changed (not just lastPollTime)

        } catch {
            if let writeIdx = courtIndex(for: courtId) {
                courts[writeIdx].errorMessage = error.localizedDescription
                courts[writeIdx].lastPollTime = Date()
            }
            // Don't change to error status on single failure
            print("⚠️ Poll error for court \(courtId): \(error.localizedDescription)")
        }
    }
    
    private func nextMatchHasStarted(_ match: MatchItem) async -> Bool {
        guard let snapshot = await fetchSnapshot(for: match) else { return false }
        return isMatchConcluded(snapshot: snapshot, for: match) || isMatchActive(snapshot) || snapshot.hasStarted
    }

    private func fetchSnapshot(for match: MatchItem, courtId: Int = 0) async -> ScoreSnapshot? {
        do {
            let data = try await scoreCache.get(match.apiURL)
            return normalizeData(data, courtId: courtId, currentMatch: match)
        } catch {
            return nil
        }
    }

    /// Walks forward from `startingAt` to find the first non-final queue index.
    /// If every remaining match is final (or we fail to fetch), returns the best-known candidate index.
    private func firstNonFinalQueueIndex(courtId: Int, startingAt startIndex: Int) async -> Int {
        var candidateIndex = startIndex

        while true {
            guard let idx = courtIndex(for: courtId),
                  candidateIndex < courts[idx].queue.count else {
                return startIndex
            }

            let candidateMatch = courts[idx].queue[candidateIndex]
            guard let snapshot = await fetchSnapshot(for: candidateMatch) else {
                return candidateIndex
            }

            if !isMatchConcluded(snapshot: snapshot, for: candidateMatch) {
                return candidateIndex
            }

            let nextIndex = candidateIndex + 1
            guard let queueIdx = courtIndex(for: courtId),
                  nextIndex < courts[queueIdx].queue.count else {
                return candidateIndex
            }

            candidateIndex = nextIndex
        }
    }
    
    /// Smart Queue Switch: Check if current match is 0-0 but another queue match has active scoring.
    /// If so, auto-switch to the active match to prioritize live content.
    private func checkForSmartQueueSwitch(courtId: Int, currentSnapshot: ScoreSnapshot) async -> Bool {
        guard let idx = courtIndex(for: courtId) else { return false }
        guard let activeIdx = courts[idx].activeIndex else { return false }

        // Only smart-switch if the current match is not actively in progress.
        guard !isMatchActive(currentSnapshot) else { return false }

        // Don't switch if we've been live on this match (liveSince set)
        if courts[idx].liveSince != nil { return false }

        // Throttle: only check every 30 seconds per court
        if Date().timeIntervalSince(lastSmartSwitchCheck[courtId] ?? .distantPast) < 30 { return false }
        lastSmartSwitchCheck[courtId] = Date()

        // Scan queue in parallel for any match with active scoring
        let queue = courts[idx].queue
        let result: Int? = await withTaskGroup(of: (Int, Bool).self) { group in
            for (queueIdx, match) in queue.enumerated() {
                guard queueIdx != activeIdx else { continue }
                group.addTask { [scoreCache] in
                    guard let data = try? await scoreCache.get(match.apiURL) else {
                        return (queueIdx, false)
                    }
                    let snapshot = await MainActor.run { self.normalizeData(data, courtId: 0, currentMatch: match) }
                    let active = await MainActor.run { self.isMatchActive(snapshot) }
                    return (queueIdx, active)
                }
            }
            for await (queueIdx, isActive) in group {
                if isActive { return queueIdx }
            }
            return nil
        }

        guard let switchIdx = result,
              let currentIdx = courtIndex(for: courtId),
              switchIdx < courts[currentIdx].queue.count else {
            return false
        }

        print("🔄 Smart Queue Switch: Found active match at index \(switchIdx). Switching from index \(activeIdx)")
        courts[currentIdx].activeIndex = switchIdx
        courts[currentIdx].lastSnapshot = nil
        courts[currentIdx].status = .waiting
        observedActiveScoring[courtId] = false
        return true
    }

    private func advanceToFirstPlayableMatchIfNeeded(courtId: Int) async {
        guard let idx = courtIndex(for: courtId),
              let activeIdx = courts[idx].activeIndex,
              activeIdx < courts[idx].queue.count else {
            return
        }

        let targetIdx = await firstNonFinalQueueIndex(courtId: courtId, startingAt: activeIdx)
        guard targetIdx > activeIdx,
              let writeIdx = courtIndex(for: courtId),
              targetIdx < courts[writeIdx].queue.count else {
            return
        }

        courts[writeIdx].activeIndex = targetIdx
        courts[writeIdx].lastSnapshot = nil
        courts[writeIdx].status = courts[writeIdx].status.isPolling ? .waiting : .idle
        courts[writeIdx].liveSince = nil
        courts[writeIdx].finishedAt = nil
        observedActiveScoring[courtId] = false
        lastScoreChangeTime[courtId] = nil
        lastScoreSnapshot[courtId] = nil

        print("⏭️ Preflight advanced court \(courtId) to match \(targetIdx + 1)")
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
                    let data = try await scoreCache.get(match.apiURL)
                    let snapshot = normalizeData(data, courtId: 0, currentMatch: match)

                    // Re-validate again before write
                    guard let writeIdx = courtIndex(for: courtId),
                          i < courts[writeIdx].queue.count else {
                        print("⚠️ Queue changed during metadata refresh, stopping early")
                        return
                    }
                    
                    var hasChanges = false

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
        print("🔄 Court change: \(matchLabel) moved from \(CourtNaming.defaultName(for: change.fromCourt)) to \(CourtNaming.defaultName(for: change.toCourt))")

        // Send notification
        let event = CourtChangeEvent(
            matchLabel: matchLabel,
            oldCourt: CourtNaming.defaultName(for: change.fromCourt),
            newCourt: CourtNaming.defaultName(for: change.toCourt),
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
    
    private static let timeRegex = try! NSRegularExpression(
        pattern: #"(\d{1,2}):(\d{2})\s*(AM|PM)"#,
        options: .caseInsensitive
    )

    private func compareTimeStrings(_ a: String, _ b: String) -> Int {
        let regex = Self.timeRegex
        guard let matchA = regex.firstMatch(in: a, range: NSRange(a.startIndex..., in: a)),
              let matchB = regex.firstMatch(in: b, range: NSRange(b.startIndex..., in: b)) else {
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

    private func determineStatus(from snapshot: ScoreSnapshot, matchConcluded: Bool) -> CourtStatus {
        if matchConcluded {
            return .finished
        } else if isMatchActive(snapshot) || snapshot.hasStarted {
            return .live
        } else {
            return .waiting
        }
    }
    
    private func isMatchConcluded(snapshot: ScoreSnapshot, for match: MatchItem?) -> Bool {
        if snapshot.status.lowercased().contains("final") {
            return true
        }

        let inferred = inferMatchFormat(from: match)
        let normalizedURL = match?.apiURL.absoluteString.lowercased() ?? ""
        let isPoolURL = normalizedURL.contains("bracket=false")

        var formats: [(setsToWin: Int, pointsPerSet: Int, pointCap: Int?)] = [inferred]
        if isPoolURL && (inferred.setsToWin > 1 || inferred.pointsPerSet > 23 || inferred.pointsPerSet < 15) {
            // Recovery path for legacy or misclassified pool formats.
            formats.append((setsToWin: 1, pointsPerSet: 21, pointCap: 23))
        }

        for format in formats {
            let setsWon = setsWon(in: snapshot, format: format)
            if setsWon.team1 >= format.setsToWin || setsWon.team2 >= format.setsToWin {
                return true
            }

            // Some payloads omit set history and only expose the active game score directly.
            if snapshot.setHistory.isEmpty && format.setsToWin == 1 {
                if isSetComplete(
                    team1: snapshot.team1Score,
                    team2: snapshot.team2Score,
                    target: format.pointsPerSet,
                    cap: format.pointCap
                ) {
                    return true
                }
            }
        }

        return false
    }

    private func setsWon(
        in snapshot: ScoreSnapshot,
        format: (setsToWin: Int, pointsPerSet: Int, pointCap: Int?)
    ) -> (team1: Int, team2: Int) {
        var team1 = 0
        var team2 = 0

        for set in snapshot.setHistory {
            let target: Int
            let cap: Int?

            if format.setsToWin > 1 && set.setNumber >= 3 {
                target = min(format.pointsPerSet, 15)
                cap = format.pointCap
            } else {
                target = format.pointsPerSet
                cap = format.pointCap
            }

            guard isSetComplete(team1: set.team1Score, team2: set.team2Score, target: target, cap: cap) else {
                continue
            }

            if set.team1Score > set.team2Score {
                team1 += 1
            } else if set.team2Score > set.team1Score {
                team2 += 1
            }
        }

        return (team1: team1, team2: team2)
    }

    private func isSetComplete(team1: Int, team2: Int, target: Int, cap: Int?) -> Bool {
        let maxScore = max(team1, team2)
        let diff = abs(team1 - team2)

        guard maxScore > 0 else {
            return false
        }

        if let cap, maxScore >= cap {
            return true
        }

        return maxScore >= target && diff >= 2
    }

    private func isMatchActive(_ snapshot: ScoreSnapshot) -> Bool {
        if snapshot.isFinal { return false }

        let status = snapshot.status.lowercased()
        if status.contains("progress") || status.contains("live") || status.contains("playing") {
            return true
        }

        if snapshot.setNumber > 1 {
            return true
        }

        if let currentSet = snapshot.setHistory.last,
           (currentSet.team1Score + currentSet.team2Score) > 0 {
            return true
        }

        if (snapshot.team1Score + snapshot.team2Score) > 0 {
            return true
        }

        return false
    }

    private func inferMatchFormat(from match: MatchItem?) -> (setsToWin: Int, pointsPerSet: Int, pointCap: Int?) {
        guard let match else {
            return (setsToWin: 2, pointsPerSet: 21, pointCap: nil)
        }

        let formatText = (match.formatText ?? "").lowercased()
        let normalizedURL = match.apiURL.absoluteString.lowercased()
        let isPoolAPIURL = normalizedURL.contains("bracket=false")
        let isPoolMatch = (match.matchType ?? "").lowercased().contains("pool")

        var setsToWin = match.setsToWin
        var pointsPerSet = match.pointsPerSet
        var pointCap = match.pointCap

        // Legacy safety: older imported pool queues were persisted as best-of-3 with missing format text.
        if isPoolAPIURL,
           formatText.isEmpty,
           (setsToWin == nil || setsToWin == 2) {
            setsToWin = 1
            if pointsPerSet == nil {
                pointsPerSet = 21
            }
            if (pointsPerSet ?? 21) == 21, pointCap == nil {
                pointCap = 23
            }
        }

        if setsToWin == nil {
            if formatText.contains("1 game") || formatText.contains("1 set") {
                setsToWin = 1
            } else if formatText.contains("best 2 out of 3") || formatText.contains("match play") {
                setsToWin = 2
            } else if isPoolMatch {
                // Most VBL pool play uses one-set format.
                setsToWin = 1
            } else {
                setsToWin = 2
            }
        }

        if pointsPerSet == nil {
            pointsPerSet =
                extractFirstInt(in: formatText, pattern: #"(?:game|set)s?\s*(?:\d+\s*(?:&|and)\s*\d+\s*)?to\s*(\d+)"#) ??
                extractFirstInt(in: formatText, pattern: #"\bto\s*(\d+)\b"#) ??
                21
        }

        if pointCap == nil {
            if formatText.contains("no cap") || formatText.contains("win by 2") {
                pointCap = nil
            } else {
                pointCap =
                    extractFirstInt(in: formatText, pattern: #"cap(?:ped)?\s*(?:at|of|is)?\s*(\d+)"#) ??
                    extractFirstInt(in: formatText, pattern: #"(\d+)\s*(?:point|pt)s?\s*cap"#)
            }

            // Safety net for older pool imports that omitted format fields.
            if pointCap == nil, (isPoolMatch || isPoolAPIURL), setsToWin == 1, pointsPerSet == 21 {
                pointCap = 23
            }
        }

        return (
            setsToWin: max(1, setsToWin ?? 2),
            pointsPerSet: max(1, pointsPerSet ?? 21),
            pointCap: pointCap
        )
    }

    // Pre-compiled regexes for match format inference (avoid re-compiling on every poll)
    private static let formatRegexCache: [String: NSRegularExpression] = {
        let patterns = [
            #"(?:game|set)s?\s*(?:\d+\s*(?:&|and)\s*\d+\s*)?to\s*(\d+)"#,
            #"\bto\s*(\d+)\b"#,
            #"cap(?:ped)?\s*(?:at|of|is)?\s*(\d+)"#,
            #"(\d+)\s*(?:point|pt)s?\s*cap"#,
            #"\b1\s*(?:game|set)\b"#,
            #"best\s*(\d+)\s*out\s*of\s*(\d+)"#,
            #"\bmatch\s*play\b"#,
        ]
        var cache: [String: NSRegularExpression] = [:]
        for p in patterns {
            cache[p] = try? NSRegularExpression(pattern: p, options: .caseInsensitive)
        }
        return cache
    }()

    private func extractFirstInt(in text: String, pattern: String) -> Int? {
        guard !text.isEmpty,
              let regex = Self.formatRegexCache[pattern] ?? (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[range])
    }

    private func normalizeLegacyPoolFormat(_ match: MatchItem) -> MatchItem {
        var normalized = match
        let formatText = (normalized.formatText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isPoolAPIURL = normalized.apiURL.absoluteString.lowercased().contains("bracket=false")

        guard isPoolAPIURL, formatText.isEmpty else {
            return normalized
        }

        if normalized.setsToWin == nil || normalized.setsToWin == 2 {
            normalized.setsToWin = 1
        }

        if normalized.pointsPerSet == nil {
            normalized.pointsPerSet = 21
        }

        if (normalized.pointsPerSet ?? 21) == 21, normalized.pointCap == nil {
            normalized.pointCap = 23
        }

        return normalized
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
        
        // Get per-match format with resilient inference fallback.
        let inferredFormat = inferMatchFormat(from: currentMatch)
        let pointsPerSet = inferredFormat.pointsPerSet
        let pointCap = inferredFormat.pointCap
        let setsToWin = inferredFormat.setsToWin
        
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
        
        // Set 3 (tiebreak: use 15 or match format if lower, e.g., training to 11)
        if setsToWin >= 2 && (g3a_raw > 0 || g3b_raw > 0) {
            let tiebreakTarget = min(pointsPerSet, 15)
            let complete = isSetComplete(g3a_raw, g3b_raw, target: tiebreakTarget, cap: pointCap)
            setHistory.append(SetScore(setNumber: 3, team1Score: g3a_raw, team2Score: g3b_raw, isComplete: complete))
            if complete {
                if g3a_raw > g3b_raw { score1 += 1 } else { score2 += 1 }
            }
        }
        
        // Calculate current set number
        let setNum = setHistory.count + (setHistory.last?.isComplete == true ? 1 : 0)

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
        let inferredFormat = inferMatchFormat(from: currentMatch)
        let setsToWin = inferredFormat.setsToWin

        let isComplete = statusStr.lowercased().contains("final")
        let setHistory = (home > 0 || away > 0)
            ? [SetScore(setNumber: setNum, team1Score: home, team2Score: away, isComplete: isComplete)]
            : [SetScore]()

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
            setHistory: setHistory,
            timestamp: Date(),
            setsToWin: setsToWin
        )
    }
    
    // MARK: - Configuration Persistence

    private lazy var configURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("MultiCourtScore")
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        return appFolder.appendingPathComponent("courts_config.json")
    }()

    private func loadConfiguration() {
        guard FileManager.default.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              let loaded = try? JSONDecoder().decode([Court].self, from: data) else {
            return
        }
        var normalizedCourts = loaded
        var didNormalize = false

        for idx in normalizedCourts.indices {
            let normalizedQueue = normalizedCourts[idx].queue.map(normalizeLegacyPoolFormat)
            if normalizedQueue != normalizedCourts[idx].queue {
                normalizedCourts[idx].queue = normalizedQueue
                didNormalize = true
            }
        }

        courts = normalizedCourts
        if didNormalize {
            saveConfigurationNow()
            print("🧹 Normalized legacy pool formats in saved queues")
        }
        print("📂 Loaded configuration with \(courts.count) courts")
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            saveConfigurationNow()
        }
    }

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()

    private func saveConfigurationNow() {
        saveTask?.cancel()
        guard let data = try? Self.jsonEncoder.encode(courts) else { return }
        try? data.write(to: configURL, options: .atomic)
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
    private let apiClient: APIClient

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    func get(_ url: URL) async throws -> Data {
        // Evict stale entries when cache grows large
        if cache.count > 50 {
            cache = cache.filter { $0.value.timestamp > Date().addingTimeInterval(-30) }
        }
        if let cached = cache[url],
           cached.timestamp.timeIntervalSinceNow > -NetworkConstants.cacheExpiration {
            return cached.data
        }

        let data = try await apiClient.fetchData(from: url)
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