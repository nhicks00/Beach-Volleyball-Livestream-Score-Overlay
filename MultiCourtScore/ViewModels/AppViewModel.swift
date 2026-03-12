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
    struct DiagnosticsManifest: Codable {
        let generatedAt: String
        let appVersion: String
        let osVersion: String
        let runtimeLogPath: String
        let serverRunning: Bool
        let signalRStatus: String
        let courtCount: Int
    }

    struct CourtDiagnosticsSnapshot: Codable {
        let id: Int
        let name: String
        let status: String
        let currentMatch: String?
        let currentMatchEndpoint: String?
        let queueCount: Int
        let activeIndex: Int?
        let overlayURL: String
        let errorMessage: String?
        let lastPollSecondsAgo: Int?
    }

    struct WatchdogRecoverySnapshot: Equatable {
        let count: Int
        let lastRecoveryAt: Date?
        let lastRecoveryReason: String?
    }

    private enum PollFailureClassification {
        case suppressedPlaceholder(statusCode: Int)
        case authenticationFailed(statusCode: Int)
        case accessForbidden(statusCode: Int)
        case rateLimited(statusCode: Int)
        case endpointMissing(statusCode: Int)
        case upstreamUnavailable(statusCode: Int)
        case invalidResponse
        case timedOut
        case networkUnavailable
        case transport(message: String)
        case unknown(message: String)

        var operatorMessage: String? {
            switch self {
            case .suppressedPlaceholder:
                return nil
            case .authenticationFailed(let statusCode):
                return "VBL API authentication failed (\(statusCode))"
            case .accessForbidden(let statusCode):
                return "VBL API access was denied (\(statusCode))"
            case .rateLimited(let statusCode):
                return "VBL API rate limited requests (\(statusCode))"
            case .endpointMissing(let statusCode):
                return "VBL match endpoint was not found (\(statusCode))"
            case .upstreamUnavailable(let statusCode):
                return "VBL API unavailable (HTTP \(statusCode))"
            case .invalidResponse:
                return "VBL API returned an invalid response"
            case .timedOut:
                return "VBL API request timed out"
            case .networkUnavailable:
                return "Network connection to VBL API failed"
            case .transport(let message):
                return "VBL API transport error: \(message)"
            case .unknown(let message):
                return message
            }
        }

        var logDetail: String {
            switch self {
            case .suppressedPlaceholder(let statusCode):
                return "suppressed placeholder response (\(statusCode))"
            case .authenticationFailed(let statusCode):
                return "authentication failed (\(statusCode))"
            case .accessForbidden(let statusCode):
                return "access denied (\(statusCode))"
            case .rateLimited(let statusCode):
                return "rate limited (\(statusCode))"
            case .endpointMissing(let statusCode):
                return "match endpoint not found (\(statusCode))"
            case .upstreamUnavailable(let statusCode):
                return "upstream unavailable (\(statusCode))"
            case .invalidResponse:
                return "invalid response"
            case .timedOut:
                return "request timed out"
            case .networkUnavailable:
                return "network unavailable"
            case .transport(let message):
                return "transport error: \(message)"
            case .unknown(let message):
                return message
            }
        }
    }

    private struct PollFailureLogState {
        let fingerprint: String
        var firstFailureAt: Date
        var lastFailureAt: Date
        var consecutiveFailures: Int
        var lastLoggedAt: Date
        var suppressedCount: Int
    }

    enum RuntimeMode {
        case live
        case uiTest
    }

    // MARK: - Published State
    @Published private(set) var courts: [Court] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: AppError?
    @Published private(set) var serverRunning = false
    @Published private(set) var signalRStatus: SignalRStatus = .disabled
    @Published var scannerViewModel = ScannerViewModel()
    @Published var appSettings: ConfigStore.AppSettings = ConfigStore.AppSettings()
    
    // MARK: - Services
    private let webSocketHub: WebSocketHub
    private let configStore: ConfigStore
    private let apiClient: APIClient
    private let scoreCache: ScoreCache
    private let notificationService: NotificationSending
    private let signalRCredentialsProvider: () -> ConfigStore.VBLCredentials?
    private let signalRClientFactory: (any SignalRDelegate) -> any SignalRClienting
    private let runtimeMode: RuntimeMode
    private let runtimeLog = RuntimeLogStore.shared
    private var signalRClient: (any SignalRClienting)?
    
    // MARK: - Private State
    private var servicesStartupTask: Task<Bool, Never>?
    private var pollingTimers: [Int: Timer] = [:]
    private var lastQueueRefreshTimes: [Int: Date] = [:]
    private var lastCourtChangeCheck: Date = .distantPast
    private var pollsInFlight: Set<Int> = []
    private var saveTask: Task<Void, Never>?
    private var watchdogTimer: Timer?
    private var lastSmartSwitchCheck: [Int: Date] = [:]
    private var smartSwitchFallbackOriginIndex: [Int: Int] = [:]
    private var smartSwitchedMatchID: [Int: UUID] = [:]
    private var pendingSmartSwitchCandidate: [Int: (queueIndex: Int, firstSeenAt: Date)] = [:]
    private enum QueueArbitrationReason: String {
        case manual = "manual"
        case queueDefault = "queue-default"
        case smartSwitch = "smart-switch"
        case laterLiveBypass = "later-live-bypass"
        case reopenRecovery = "reopen-recovery"
        case ambiguousHold = "ambiguous-hold"
    }
    private var queueArbitrationReasonByCourt: [Int: QueueArbitrationReason] = [:]
    private var lastQueueArbitrationNoteByCourt: [Int: String] = [:]
    private var lastSignalRReconcileAt: [Int: Date] = [:]
    private var lastSignalRMutationAt: [Int: Date] = [:]
    private var lastSignalRMutationEpochMs: [Int: Int64] = [:]
    private var lastSignalRMutationFallbackAt: [Int: Date] = [:]
    private var signalRMutationFallbackCourts: Set<Int> = []
    private var signalRMutationFallbackAttemptsByCourt: [Int: Int] = [:]
    private var lastSignalRUnknownGameRefreshAt: [Int: Date] = [:]
    private var forcedBroadcastLiveLayoutByCourt: Set<Int> = []
    private var watchdogRecoveryCount = 0
    private var lastWatchdogRecoveryAt: Date?
    private var lastWatchdogRecoveryReason: String?
    private struct RecentlyAdvancedMatchContext {
        let match: MatchItem
        let advancedAt: Date
    }

    // SignalR game ID → court mapping
    private var gameIdToCourtMap: [Int: Int] = [:]       // gameId → courtId
    private var ambiguousGameIdToCourtIds: [Int: Set<Int>] = [:]
    private var activeSubscriptions: [Int: Set<Int>] = [:] // tournamentId → set of divisionIds
    private var recentlyAutoAdvancedMatches: [Int: RecentlyAdvancedMatchContext] = [:]

    // Inactivity tracking
    private var lastScoreSnapshot: [Int: (pts1: Int, pts2: Int, s1: Int, s2: Int)] = [:]
    private var lastScoreChangeTime: [Int: Date] = [:]
    // Per-court flag indicating we observed non-final live scoring for current active match.
    private var observedActiveScoring: [Int: Bool] = [:]
    // Server-side serve tracking: infer serving team from score changes
    private var lastServeTeam: [Int: String] = [:]
    // Periodic hydrate re-fetch for resolving TBD bracket teams
    private var lastHydrateRefresh: [Int: Date] = [:]  // divisionId → last fetch time
    private static let hydrateRefreshInterval: TimeInterval = 60  // seconds
    var weakSmartSwitchConfirmationWindow: TimeInterval = 8
    // Placeholder pool endpoints can return repeated upstream 500s while a match
    // is still synthetic. Keep the first log line and then rate-limit reminders.
    private var placeholderSuppressionLogTimes: [Int: [String: Date]] = [:]
    private var queueMetadataSuppressionLogTimes: [Int: [String: Date]] = [:]
    private var pollFailureLogStates: [Int: PollFailureLogState] = [:]
    private static let placeholderSuppressionLogInterval: TimeInterval = 300
    private static let pollFailureLogInterval: TimeInterval = 120

    var isUITestMode: Bool {
        runtimeMode == .uiTest
    }
    
    // MARK: - Initialization
    
    init() {
        let configStore = ConfigStore()
        self.runtimeMode = Self.detectRuntimeMode()
        self.webSocketHub = .shared
        self.configStore = configStore
        self.apiClient = APIClient()
        self.scoreCache = ScoreCache(apiClient: apiClient)
        self.notificationService = NotificationService.shared
        self.signalRCredentialsProvider = { configStore.loadCredentials() }
        self.signalRClientFactory = { delegate in VBLSignalRClient(delegate: delegate) }
        self.appSettings = configStore.loadSettings()

        loadConfiguration()
        ensureAllCourtsExist()
        if isUITestMode {
            loadUITestScenario()
        }
    }

    init(
        runtimeMode: RuntimeMode,
        webSocketHub: WebSocketHub,
        configStore: ConfigStore,
        apiClient: APIClient,
        notificationService: NotificationSending = NotificationService.shared,
        signalRCredentialsProvider: (() -> ConfigStore.VBLCredentials?)? = nil,
        signalRClientFactory: ((any SignalRDelegate) -> any SignalRClienting)? = nil
    ) {
        self.runtimeMode = runtimeMode
        self.webSocketHub = webSocketHub
        self.configStore = configStore
        self.apiClient = apiClient
        self.scoreCache = ScoreCache(apiClient: apiClient)
        self.notificationService = notificationService
        self.signalRCredentialsProvider = signalRCredentialsProvider ?? { configStore.loadCredentials() }
        self.signalRClientFactory = signalRClientFactory ?? { delegate in VBLSignalRClient(delegate: delegate) }
        self.appSettings = configStore.loadSettings()
        
        loadConfiguration()
        ensureAllCourtsExist()
        if isUITestMode {
            loadUITestScenario()
        }
    }
    
    // MARK: - Services Lifecycle

    func startServices() {
        Task { @MainActor in
            _ = await ensureServicesRunning()
        }
    }

    func retryServicesRestoringPollingIfConfigured() {
        runtimeLog.log(.info, subsystem: "operator", message: "requested service retry from dashboard")
        Task { @MainActor in
            let didStart = await ensureServicesRunning()
            if didStart && appSettings.autoStartPolling {
                startAllPolling()
            }
        }
    }

    @discardableResult
    func ensureServicesRunning() async -> Bool {
        guard !isUITestMode else {
            serverRunning = true
            error = nil
            return true
        }

        if webSocketHub.isRunning {
            webSocketHub.appViewModel = self
            serverRunning = true
            if webSocketHub.startupError == nil {
                error = nil
            }
            return true
        }

        if let startupTask = servicesStartupTask {
            return await startupTask.value
        }

        let port = appSettings.serverPort
        let shouldEnableSignalR = appSettings.signalREnabled

        let startupTask = Task<Bool, Never> { @MainActor [weak self] in
            guard let self else { return false }

            await self.webSocketHub.start(with: self, port: port)

            let didStart = self.webSocketHub.isRunning
            self.serverRunning = didStart

            if let startupError = self.webSocketHub.startupError {
                self.error = .configError(startupError)
                self.stopWatchdog()
                self.stopSignalR()
                self.runtimeLog.log(
                    .error,
                    subsystem: "app-lifecycle",
                    message: "services failed to start on port \(port): \(startupError)"
                )
            } else {
                self.error = nil
                self.startWatchdog()
                if shouldEnableSignalR {
                    self.startSignalR()
                } else {
                    self.stopSignalR()
                }
                self.runtimeLog.log(.info, subsystem: "app-lifecycle", message: "services started on port \(port)")
            }

            self.servicesStartupTask = nil
            return didStart
        }

        servicesStartupTask = startupTask
        return await startupTask.value
    }

    func stopServices() {
        guard !isUITestMode else {
            serverRunning = false
            return
        }

        servicesStartupTask?.cancel()
        servicesStartupTask = nil
        stopAllPolling()
        stopWatchdog()
        stopSignalR()
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

    private func normalizedIdentityComponent(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " / ", with: "/")
            .nilIfEmpty()
    }

    private func stableMatchIdentityKey(
        team1: String?,
        team2: String?,
        matchNumber: String?,
        divisionId: Int?
    ) -> String? {
        guard let name1 = normalizedIdentityComponent(team1),
              let name2 = normalizedIdentityComponent(team2) else {
            return nil
        }

        let orderedTeams = [name1, name2].sorted().joined(separator: "|")
        let matchPart = normalizedIdentityComponent(matchNumber) ?? "no-match-number"
        let divisionPart = divisionId.map(String.init) ?? "no-division"
        return "\(divisionPart)|\(matchPart)|\(orderedTeams)"
    }

    private func stableMatchIdentityKey(for match: MatchItem) -> String? {
        stableMatchIdentityKey(
            team1: match.team1Name,
            team2: match.team2Name,
            matchNumber: match.matchNumber,
            divisionId: match.divisionId
        )
    }

    private func matchesRepresentSameContest(_ lhs: MatchItem, _ rhs: MatchItem) -> Bool {
        stableMatchIdentityKey(for: lhs) == stableMatchIdentityKey(for: rhs)
    }
    
    // MARK: - Court Management
    
    func renameCourt(_ courtId: Int, to newName: String) {
        guard let idx = courtIndex(for: courtId) else { return }
        let previousName = courts[idx].displayName
        courts[idx].name = newName
        saveConfigurationNow()
        runtimeLog.log(.info, subsystem: "operator", message: "renamed court \(courtId) from '\(previousName)' to '\(courts[idx].displayName)'")
    }

    func setScoreboardLayout(_ courtId: Int, layout: String?) {
        guard let idx = courtIndex(for: courtId) else { return }
        courts[idx].scoreboardLayout = layout
        saveConfigurationNow()
        runtimeLog.log(.info, subsystem: "operator", message: "set scoreboard layout for court \(courtId) to \(layout ?? "default")")
    }

    func setCourtSocialBarEnabled(_ courtId: Int, isEnabled: Bool?) {
        guard let idx = courtIndex(for: courtId) else { return }
        courts[idx].socialBarEnabled = isEnabled
        saveConfigurationNow()
        runtimeLog.log(.info, subsystem: "operator", message: "set social bar for court \(courtId) to \(isEnabled.map(String.init) ?? "default")")
    }

    func setCourtNextMatchBarEnabled(_ courtId: Int, isEnabled: Bool?) {
        guard let idx = courtIndex(for: courtId) else { return }
        courts[idx].nextMatchBarEnabled = isEnabled
        saveConfigurationNow()
        runtimeLog.log(.info, subsystem: "operator", message: "set next match bar for court \(courtId) to \(isEnabled.map(String.init) ?? "default")")
    }

    func effectiveSocialBarEnabled(for court: Court) -> Bool {
        court.socialBarEnabled ?? appSettings.showSocialBar
    }

    func effectiveNextMatchBarEnabled(for court: Court) -> Bool {
        court.nextMatchBarEnabled ?? appSettings.showNextMatchBar
    }

    func effectiveLiveScoreboardLayout(for court: Court) -> String {
        court.scoreboardLayout ?? appSettings.defaultScoreboardLayout
    }

    func effectiveOverlayState(for court: Court) -> String {
        let liveLayout = effectiveLiveScoreboardLayout(for: court)
        let forceLiveLayout = forcedBroadcastLiveLayoutByCourt.contains(court.id)

        if forceLiveLayout,
           appSettings.broadcastTransitionsEnabled,
           court.currentMatch != nil,
           liveLayout != "center" {
            return "scoring"
        }

        let shouldUseIntermission = Self.shouldUseBroadcastIntermissionLayout(
            broadcastTransitionsEnabled: appSettings.broadcastTransitionsEnabled,
            liveLayout: liveLayout,
            courtStatus: court.status,
            hasCurrentMatch: court.currentMatch != nil,
            hasScoreEvidence: courtHasLiveScoreEvidence(court),
            forceLiveLayout: forceLiveLayout
        )

        if shouldUseIntermission {
            return "intermission"
        }

        return (court.status == .live || court.status == .finished) ? "scoring" : "intermission"
    }

    func effectiveOverlayLayout(for court: Court) -> String {
        effectiveOverlayState(for: court) == "intermission" ? "center" : effectiveLiveScoreboardLayout(for: court)
    }

    func canForceBroadcastLiveLayout(for court: Court) -> Bool {
        appSettings.broadcastTransitionsEnabled
            && court.status.isPolling
            && court.currentMatch != nil
            && effectiveLiveScoreboardLayout(for: court) != "center"
            && effectiveOverlayState(for: court) == "intermission"
    }

    func forceBroadcastLiveLayout(_ courtId: Int) {
        guard let idx = courtIndex(for: courtId) else { return }
        let court = courts[idx]
        let liveLayout = effectiveLiveScoreboardLayout(for: court)
        guard appSettings.broadcastTransitionsEnabled,
              court.status.isPolling,
              court.currentMatch != nil,
              liveLayout != "center" else {
            return
        }

        forcedBroadcastLiveLayoutByCourt.insert(courtId)
        runtimeLog.log(.info, subsystem: "operator", message: "forced broadcast live layout for court \(courtId) to \(liveLayout)")
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
        forcedBroadcastLiveLayoutByCourt.remove(courtId)
        smartSwitchFallbackOriginIndex.removeValue(forKey: courtId)
        smartSwitchedMatchID.removeValue(forKey: courtId)
        pendingSmartSwitchCandidate.removeValue(forKey: courtId)
        recentlyAutoAdvancedMatches.removeValue(forKey: courtId)
        queueArbitrationReasonByCourt[courtId] = defaultQueueArbitrationReason(for: courts[idx].activeIndex)
        lastQueueArbitrationNoteByCourt.removeValue(forKey: courtId)
        clearSuppressionLogState(for: courtId)
        saveConfigurationNow()
        runtimeLog.log(.info, subsystem: "operator", message: "replaced queue for court \(courtId) with \(items.count) matches")
    }

    /// Replace a queue after manual editing while preserving the active match when possible.
    ///
    /// If the currently active match still exists in the edited queue, keep focus on that match.
    /// Runtime state is preserved only when the active match keeps the same API URL; otherwise
    /// snapshot/live timing is cleared and polling falls back to waiting.
    func replaceQueuePreservingState(_ courtId: Int, with items: [MatchItem]) {
        guard let idx = courtIndex(for: courtId) else { return }

        let normalizedItems = items.map(normalizeLegacyPoolFormat)
        let previousCourt = courts[idx]
        let previousActiveMatch: MatchItem? = {
            guard let activeIdx = previousCourt.activeIndex,
                  previousCourt.queue.indices.contains(activeIdx) else {
                return nil
            }
            return previousCourt.queue[activeIdx]
        }()
        let previousWasPolling = previousCourt.status.isPolling

        courts[idx].queue = normalizedItems
        smartSwitchFallbackOriginIndex.removeValue(forKey: courtId)
        smartSwitchedMatchID.removeValue(forKey: courtId)
        pendingSmartSwitchCandidate.removeValue(forKey: courtId)
        recentlyAutoAdvancedMatches.removeValue(forKey: courtId)
        lastQueueArbitrationNoteByCourt.removeValue(forKey: courtId)
        forcedBroadcastLiveLayoutByCourt.remove(courtId)

        guard !normalizedItems.isEmpty else {
            courts[idx].activeIndex = nil
            courts[idx].status = .idle
            courts[idx].lastSnapshot = nil
            courts[idx].liveSince = nil
            courts[idx].finishedAt = nil
            courts[idx].errorMessage = nil
            observedActiveScoring[courtId] = false
            forcedBroadcastLiveLayoutByCourt.remove(courtId)
            clearSuppressionLogState(for: courtId)
            queueArbitrationReasonByCourt.removeValue(forKey: courtId)
            saveConfigurationNow()
            runtimeLog.log(.info, subsystem: "operator", message: "saved queue editor changes for court \(courtId); queue emptied")
            return
        }

        if let previousActiveMatch,
           let preservedIndex = normalizedItems.firstIndex(where: {
               $0.id == previousActiveMatch.id || matchesRepresentSameContest($0, previousActiveMatch)
           }) {
            courts[idx].activeIndex = preservedIndex

            if normalizedItems[preservedIndex].apiURL != previousActiveMatch.apiURL {
                courts[idx].status = previousWasPolling ? .waiting : .idle
                courts[idx].lastSnapshot = nil
                courts[idx].liveSince = nil
                courts[idx].finishedAt = nil
                courts[idx].errorMessage = nil
                observedActiveScoring[courtId] = false
                forcedBroadcastLiveLayoutByCourt.remove(courtId)
            }
        } else {
            let fallbackIndex = min(previousCourt.activeIndex ?? 0, normalizedItems.count - 1)
            courts[idx].activeIndex = max(0, fallbackIndex)
            courts[idx].status = previousWasPolling ? .waiting : .idle
            courts[idx].lastSnapshot = nil
            courts[idx].liveSince = nil
            courts[idx].finishedAt = nil
            courts[idx].errorMessage = nil
            observedActiveScoring[courtId] = false
            forcedBroadcastLiveLayoutByCourt.remove(courtId)
        }

        queueArbitrationReasonByCourt[courtId] = defaultQueueArbitrationReason(for: courts[idx].activeIndex)
        clearSuppressionLogState(for: courtId)
        saveConfigurationNow()
        runtimeLog.log(
            .info,
            subsystem: "operator",
            message: "saved queue editor changes for court \(courtId); \(normalizedItems.count) matches, active index \(courts[idx].activeIndex ?? -1)"
        )
    }

    func appendToQueue(_ courtId: Int, items: [MatchItem]) {
        guard let idx = courtIndex(for: courtId) else { return }
        courts[idx].queue.append(contentsOf: items.map(normalizeLegacyPoolFormat))
        if courts[idx].activeIndex == nil && !items.isEmpty {
            courts[idx].activeIndex = 0
        }
        clearSuppressionLogState(for: courtId)
        saveConfigurationNow()
        runtimeLog.log(.info, subsystem: "operator", message: "appended \(items.count) matches to court \(courtId)")
    }

    /// Merge new scan results into an existing queue without disrupting active state.
    ///
    /// Matches are correlated by exact endpoint URL first, then by stable team-name/match-number key.
    /// This lets a re-scan refresh placeholders into resolved team names without duplicating the
    /// queued item, while still handling live URL changes once a match begins scoring.
    /// - Existing items get their URL and metadata updated in-place.
    /// - New items (not in current queue) are appended.
    /// - Active index, status, snapshot, polling — all preserved.
    func mergeQueue(_ courtId: Int, with newItems: [MatchItem]) {
        guard let idx = courtIndex(for: courtId) else { return }
        var queue = courts[idx].queue

        let normalizedNew = newItems.map { normalizeLegacyPoolFormat($0) }

        // Track which new items matched an existing queue entry (by index)
        var consumedNewIndices = Set<Int>()

        // Pass 1: Update existing items in-place
        for qi in queue.indices {
            if let ni = matchingMergeCandidateIndex(
                for: queue[qi],
                in: normalizedNew,
                consumedNewIndices: consumedNewIndices
            ) {
                let updated = normalizedNew[ni]
                queue[qi].label = updated.label ?? queue[qi].label
                queue[qi].team1Name = updated.team1Name ?? queue[qi].team1Name
                queue[qi].team2Name = updated.team2Name ?? queue[qi].team2Name
                queue[qi].team1Seed = updated.team1Seed ?? queue[qi].team1Seed
                queue[qi].team2Seed = updated.team2Seed ?? queue[qi].team2Seed
                queue[qi].apiURL = updated.apiURL
                queue[qi].matchType = updated.matchType ?? queue[qi].matchType
                queue[qi].typeDetail = updated.typeDetail ?? queue[qi].typeDetail
                queue[qi].scheduledTime = updated.scheduledTime ?? queue[qi].scheduledTime
                queue[qi].startDate = updated.startDate ?? queue[qi].startDate
                queue[qi].courtNumber = updated.courtNumber ?? queue[qi].courtNumber
                queue[qi].physicalCourt = updated.physicalCourt ?? queue[qi].physicalCourt
                queue[qi].setsToWin = updated.setsToWin ?? queue[qi].setsToWin
                queue[qi].setsToPlay = updated.setsToPlay ?? queue[qi].setsToPlay
                queue[qi].pointsPerSet = updated.pointsPerSet ?? queue[qi].pointsPerSet
                queue[qi].pointCap = updated.pointCap ?? queue[qi].pointCap
                queue[qi].formatText = updated.formatText ?? queue[qi].formatText
                queue[qi].divisionId = updated.divisionId ?? queue[qi].divisionId
                queue[qi].tournamentId = updated.tournamentId ?? queue[qi].tournamentId
                queue[qi].gameIds = updated.gameIds ?? queue[qi].gameIds
                consumedNewIndices.insert(ni)
            }
        }

        // Pass 2: Append any new items that didn't match existing queue entries
        for ni in normalizedNew.indices where !consumedNewIndices.contains(ni) {
            queue.append(normalizedNew[ni])
        }

        courts[idx].queue = queue
        // activeIndex, status, lastSnapshot, liveSince, finishedAt — all untouched
        clearSuppressionLogState(for: courtId)
        saveConfigurationNow()
        runtimeLog.log(
            .info,
            subsystem: "queue",
            message: "merged court \(courtId): updated \(consumedNewIndices.count) existing, appended \(normalizedNew.count - consumedNewIndices.count) new"
        )
    }

    private func matchingMergeCandidateIndex(
        for existing: MatchItem,
        in normalizedNew: [MatchItem],
        consumedNewIndices: Set<Int>
    ) -> Int? {
        if let exactURLMatch = normalizedNew.indices.first(where: {
            !consumedNewIndices.contains($0) && normalizedNew[$0].apiURL == existing.apiURL
        }) {
            return exactURLMatch
        }

        let existingKey = matchKey(for: existing)
        return normalizedNew.indices.first(where: {
            !consumedNewIndices.contains($0) && matchKey(for: normalizedNew[$0]) == existingKey
        })
    }

    /// Generate a stable fallback key for matching queue items across scans when endpoint URLs differ.
    private func matchKey(for item: MatchItem) -> String {
        let t1 = (item.team1Name ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        let t2 = (item.team2Name ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        // Include match number to disambiguate rematches (same teams, different round)
        let num = item.matchNumber ?? ""
        return "\(t1)|\(t2)|\(num)"
    }

    func clearQueue(_ courtId: Int) {
        replaceQueue(courtId, with: [])
        stopPolling(for: courtId)
        runtimeLog.log(.warning, subsystem: "operator", message: "cleared queue for court \(courtId)")
    }

    func clearAllQueues() {
        stopAllPolling()
        pollsInFlight.removeAll()
        gameIdToCourtMap.removeAll()
        lastQueueRefreshTimes.removeAll()
        lastHydrateRefresh.removeAll()
        lastSignalRReconcileAt.removeAll()
        lastSignalRMutationAt.removeAll()
        lastSignalRMutationEpochMs.removeAll()
        lastSignalRMutationFallbackAt.removeAll()
        signalRMutationFallbackCourts.removeAll()
        signalRMutationFallbackAttemptsByCourt.removeAll()
        lastSignalRUnknownGameRefreshAt.removeAll()
        lastSmartSwitchCheck.removeAll()
        smartSwitchFallbackOriginIndex.removeAll()
        smartSwitchedMatchID.removeAll()
        pendingSmartSwitchCandidate.removeAll()
        queueArbitrationReasonByCourt.removeAll()
        lastQueueArbitrationNoteByCourt.removeAll()
        forcedBroadcastLiveLayoutByCourt.removeAll()
        for i in courts.indices {
            let courtId = courts[i].id
            courts[i].queue = []
            courts[i].activeIndex = nil
            courts[i].status = .idle
            courts[i].lastSnapshot = nil
            courts[i].liveSince = nil
            courts[i].finishedAt = nil
            courts[i].lastPollTime = nil
            courts[i].errorMessage = nil
            observedActiveScoring.removeValue(forKey: courtId)
            smartSwitchFallbackOriginIndex.removeValue(forKey: courtId)
            smartSwitchedMatchID.removeValue(forKey: courtId)
            pendingSmartSwitchCandidate.removeValue(forKey: courtId)
            lastScoreChangeTime.removeValue(forKey: courtId)
            lastScoreSnapshot.removeValue(forKey: courtId)
            lastServeTeam.removeValue(forKey: courtId)
            clearSuppressionLogState(for: courtId)
        }
        runtimeLog.log(.warning, subsystem: "queue", message: "cleared all court queues and reset runtime state")
        saveConfigurationNow()
    }
    
    // MARK: - Polling Control
    
    func startPolling(for courtId: Int) {
        Task { @MainActor in
            guard await ensureServicesRunning() else {
                runtimeLog.log(
                    .warning,
                    subsystem: "operator",
                    message: "blocked polling start for court \(courtId) because overlay server is unavailable"
                )
                return
            }
            startPollingAfterServices(for: courtId)
        }
    }

    private func startPollingAfterServices(for courtId: Int) {
        guard let idx = courtIndex(for: courtId) else { return }
        guard !courts[idx].queue.isEmpty else { return }

        if isUITestMode {
            if courts[idx].activeIndex == nil {
                courts[idx].activeIndex = 0
            }
            courts[idx].status = courts[idx].lastSnapshot == nil ? .waiting : .live
            courts[idx].lastPollTime = Date()
            courts[idx].errorMessage = nil
            observedActiveScoring[courtId] = courts[idx].lastSnapshot != nil
            saveConfigurationNow()
            return
        }
        
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
        forcedBroadcastLiveLayoutByCourt.remove(courtId)
        lastSignalRReconcileAt[courtId] = Date().addingTimeInterval(-NetworkConstants.signalRReconcilePollInterval)
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

        rebuildGameIdMap()
        saveConfigurationNow()
        syncSignalRSubscriptions()
        runtimeLog.log(.info, subsystem: "polling", message: "started polling for court \(courtId)")
        runtimeLog.log(.info, subsystem: "operator", message: "started polling for court \(courtId)")
    }
    
    func stopPolling(for courtId: Int) {
        pollingTimers[courtId]?.invalidate()
        pollingTimers[courtId] = nil
        pollsInFlight.remove(courtId)
        observedActiveScoring.removeValue(forKey: courtId)
        lastScoreChangeTime.removeValue(forKey: courtId)
        lastScoreSnapshot.removeValue(forKey: courtId)
        lastSignalRReconcileAt.removeValue(forKey: courtId)
        lastSignalRMutationAt.removeValue(forKey: courtId)
        lastSignalRMutationEpochMs.removeValue(forKey: courtId)
        clearSignalRMutationFallbackState(for: courtId)
        smartSwitchFallbackOriginIndex.removeValue(forKey: courtId)
        smartSwitchedMatchID.removeValue(forKey: courtId)
        pendingSmartSwitchCandidate.removeValue(forKey: courtId)
        recentlyAutoAdvancedMatches.removeValue(forKey: courtId)
        queueArbitrationReasonByCourt.removeValue(forKey: courtId)
        lastQueueArbitrationNoteByCourt.removeValue(forKey: courtId)
        forcedBroadcastLiveLayoutByCourt.remove(courtId)

        if let idx = courtIndex(for: courtId) {
            courts[idx].status = .idle
            courts[idx].liveSince = nil
        }
        scheduleSave()
        syncSignalRSubscriptions()
        runtimeLog.log(.info, subsystem: "polling", message: "stopped polling for court \(courtId)")
        runtimeLog.log(.info, subsystem: "operator", message: "stopped polling for court \(courtId)")
    }
    
    func startAllPolling() {
        Task { @MainActor in
            guard await ensureServicesRunning() else {
                runtimeLog.log(
                    .warning,
                    subsystem: "operator",
                    message: "blocked start-all because overlay server is unavailable"
                )
                return
            }

            let eligibleCourts = courts.filter { !$0.queue.isEmpty && pollingTimers[$0.id] == nil }.map(\.id)
            for court in courts where !court.queue.isEmpty {
                if pollingTimers[court.id] == nil {
                    startPollingAfterServices(for: court.id)
                }
            }
            runtimeLog.log(.info, subsystem: "operator", message: "started all polling for courts \(eligibleCourts)")
        }
    }
    
    func stopAllPolling() {
        // Stop all active timers
        let activeCourts = Array(pollingTimers.keys).sorted()
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
        runtimeLog.log(.warning, subsystem: "operator", message: "stopped all polling for courts \(activeCourts)")
    }

    /// Deterministic single poll-cycle hook used by tests.
    func runImmediatePollCycleForTesting(courtId: Int) async {
        guard !isUITestMode else { return }
        guard let idx = courtIndex(for: courtId),
              !courts[idx].queue.isEmpty else { return }

        if courts[idx].activeIndex == nil {
            courts[idx].activeIndex = 0
        }
        if !courts[idx].status.isPolling {
            courts[idx].status = .waiting
        }

        await advanceToFirstPlayableMatchIfNeeded(courtId: courtId)
        await pollOnce(courtId)
    }

    /// Deterministic court-reassignment hook used by tests.
    func runCourtChangeForTesting(matchId: UUID, fromCourt: Int, toCourt: Int) async {
        guard let fromIdx = courtIndex(for: fromCourt),
              let match = courts[fromIdx].queue.first(where: { $0.id == matchId }) else {
            return
        }

        await processCourtChange((
            matchId: matchId,
            fromCourt: fromCourt,
            toCourt: toCourt,
            match: match
        ))
    }

    /// Test-only cache reset so multi-step polling scenarios can swap fixtures deterministically.
    func clearScoreCacheForTesting() async {
        await scoreCache.clearAll()
    }

    /// Test-only hook to force the next queue metadata refresh path to run immediately.
    func resetQueueMetadataRefreshForTesting(courtId: Int) {
        lastQueueRefreshTimes[courtId] = .distantPast
    }

    /// Test-only hook to drive the shared snapshot transition path directly.
    func applySnapshotForTesting(
        courtId: Int,
        snapshot: ScoreSnapshot,
        allowStaleAdvance: Bool = false
    ) async -> Bool {
        guard let idx = courtIndex(for: courtId),
              let activeIdx = courts[idx].activeIndex,
              activeIdx < courts[idx].queue.count else {
            return false
        }

        return await applySnapshotUpdate(
            courtId: courtId,
            snapshot: snapshot,
            matchItem: courts[idx].queue[activeIdx],
            allowStaleAdvance: allowStaleAdvance
        )
    }

    /// Test-only hook to refresh SignalR game-id routing after queue setup.
    func rebuildGameIdMapForTesting() {
        rebuildGameIdMap()
    }

    /// Test-only hook to run the watchdog health check deterministically.
    func runWatchdogCheckForTesting() async {
        await checkPollingHealth()
    }

    /// Test-only hook to inject watchdog recovery metadata without booting shared services.
    func recordWatchdogRecoveryForTesting(
        reason: String,
        at date: Date = Date()
    ) {
        recordWatchdogRecovery(reason: reason, at: date)
    }

    /// Test-only hook to mark a court as actively polling without going through timer setup.
    func setPollingStateForTesting(
        courtId: Int,
        status: CourtStatus = .waiting,
        lastPollTime: Date? = Date()
    ) {
        guard let idx = courtIndex(for: courtId),
              !courts[idx].queue.isEmpty else {
            return
        }

        if courts[idx].activeIndex == nil {
            courts[idx].activeIndex = 0
        }
        courts[idx].status = status
        courts[idx].lastPollTime = lastPollTime
        courts[idx].errorMessage = nil
    }

    func setSignalRMutationStateForTesting(
        courtId: Int,
        lastMutationAt: Date?
    ) {
        if let lastMutationAt {
            lastSignalRMutationAt[courtId] = lastMutationAt
            return
        }

        lastSignalRMutationAt.removeValue(forKey: courtId)
    }

    func hasSignalRMutationStateForTesting(courtId: Int) -> Bool {
        lastSignalRMutationAt[courtId] != nil
    }

    func signalRReconcileAnchorForTesting(courtId: Int) -> Date? {
        lastSignalRReconcileAt[courtId]
    }

    func signalRMutationFallbackSnapshotForTesting() -> (count: Int, courts: [Int]) {
        currentSignalRMutationFallbackSnapshot()
    }

    func currentWatchdogRecoverySnapshot() -> WatchdogRecoverySnapshot {
        WatchdogRecoverySnapshot(
            count: watchdogRecoveryCount,
            lastRecoveryAt: lastWatchdogRecoveryAt,
            lastRecoveryReason: lastWatchdogRecoveryReason
        )
    }

    func registerPollFailureForTesting(
        courtId: Int,
        fingerprint: String,
        at date: Date = Date()
    ) -> Int? {
        preparePollFailureLog(for: courtId, fingerprint: fingerprint, now: date)
    }

    func currentPollFailureLogStateForTesting(
        courtId: Int
    ) -> (
        fingerprint: String,
        suppressedCount: Int,
        consecutiveFailures: Int,
        firstFailureAt: Date,
        lastFailureAt: Date
    )? {
        guard let state = pollFailureLogStates[courtId] else { return nil }
        return (
            state.fingerprint,
            state.suppressedCount,
            state.consecutiveFailures,
            state.firstFailureAt,
            state.lastFailureAt
        )
    }

    func currentCourtOperationalHealth(for courtId: Int) -> CourtOperationalHealth? {
        guard let state = pollFailureLogStates[courtId] else { return nil }
        return CourtOperationalHealth(
            consecutivePollFailures: state.consecutiveFailures,
            degradedSince: state.firstFailureAt,
            lastFailureAt: state.lastFailureAt,
            lastFailureFingerprint: state.fingerprint
        )
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
            forcedBroadcastLiveLayoutByCourt.remove(courtId)
            recentlyAutoAdvancedMatches.removeValue(forKey: courtId)
            queueArbitrationReasonByCourt[courtId] = .manual
            lastQueueArbitrationNoteByCourt.removeValue(forKey: courtId)
            saveConfigurationNow()
            runtimeLog.log(.info, subsystem: "operator", message: "advanced court \(courtId) from queue index \(activeIdx) to \(nextIndex)")
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
        forcedBroadcastLiveLayoutByCourt.remove(courtId)
        recentlyAutoAdvancedMatches.removeValue(forKey: courtId)
        queueArbitrationReasonByCourt[courtId] = .manual
        lastQueueArbitrationNoteByCourt.removeValue(forKey: courtId)
        saveConfigurationNow()
        runtimeLog.log(.info, subsystem: "operator", message: "moved court \(courtId) back from queue index \(activeIdx) to \(activeIdx - 1)")
    }

    // MARK: - Overlay URL
    
    func overlayURL(for courtId: Int) -> String {
        return "http://localhost:\(appSettings.serverPort)/overlay/court/\(courtId)/"
    }

    func suggestedDiagnosticsBundleFilename(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "MultiCourtScore-diagnostics-\(formatter.string(from: date)).zip"
    }

    func supportSummaryText(
        runtimeLog: RuntimeLogStore = .shared,
        date: Date = Date()
    ) -> String {
        let timestamp = ISO8601DateFormatter().string(from: date)
        webSocketHub.appViewModel = self
        let healthSnapshot = webSocketHub.currentHealthSnapshot(port: appSettings.serverPort)
        let courtSnapshots = currentCourtDiagnosticsSnapshots(referenceDate: date)

        let pollingCount = courts.filter { $0.status.isPolling }.count
        let liveCount = courts.filter { $0.status == .live }.count
        let waitingCount = courts.filter { $0.status == .waiting }.count
        let idleCount = courts.filter { $0.status == .idle }.count
        let errorCount = courts.filter { $0.status == .error }.count
        let staleCourtsText = healthSnapshot.stalePollingCourtIds.isEmpty
            ? "none"
            : healthSnapshot.stalePollingCourtIds.map(String.init).joined(separator: ", ")
        let errorCourtsText = healthSnapshot.errorCourtIds.isEmpty
            ? "none"
            : healthSnapshot.errorCourtIds.map(String.init).joined(separator: ", ")
        let watchdogRecoveryText: String
        if healthSnapshot.watchdogRestartCount > 0 {
            if let lastRecoveryAt = healthSnapshot.lastWatchdogRecoveryAt {
                watchdogRecoveryText = "\(healthSnapshot.watchdogRestartCount) (last: \(lastRecoveryAt), reason: \(healthSnapshot.lastWatchdogRecoveryReason ?? "unknown"))"
            } else {
                watchdogRecoveryText = "\(healthSnapshot.watchdogRestartCount)"
            }
        } else {
            watchdogRecoveryText = "none"
        }

        let notableCourts = courtSnapshots.filter {
            $0.queueCount > 0 || $0.errorMessage != nil || $0.status != CourtStatus.idle.rawValue
        }

        var lines: [String] = [
            "MultiCourtScore Support Summary",
            "Generated: \(timestamp)",
            "App Version: \(AppConfig.version)",
            "OS Version: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Health: \(healthSnapshot.status.uppercased())",
            "Overlay Server: \(healthSnapshot.serverStatus) on localhost:\(healthSnapshot.port)",
            "SignalR: \(healthSnapshot.signalREnabled ? healthSnapshot.signalRStatus : "Disabled")",
            "Runtime Log: \(runtimeLog.logFilePath)",
            "Courts: \(courts.count) total | polling \(pollingCount) | live \(liveCount) | waiting \(waitingCount) | idle \(idleCount) | error \(errorCount)",
            "Watchdog Recoveries: \(watchdogRecoveryText)",
            "Stale Courts: \(staleCourtsText)",
            "Error Courts: \(errorCourtsText)"
        ]

        if healthSnapshot.signalRMutationFallbackCount > 0 {
            let fallbackCourtsText = healthSnapshot.signalRMutationFallbackCourts.isEmpty
                ? "none"
                : healthSnapshot.signalRMutationFallbackCourts.map(String.init).joined(separator: ", ")
            lines.append("SignalR Mutation Fallback Polls: \(healthSnapshot.signalRMutationFallbackCount) on courts \(fallbackCourtsText)")
        }

        if let startupError = healthSnapshot.startupError, !startupError.isEmpty {
            lines.append("Startup Error: \(startupError)")
        }

        let activeAlerts = activeSupportAlerts(
            healthSnapshot: healthSnapshot,
            courtSnapshots: courtSnapshots
        )
        if !activeAlerts.isEmpty {
            lines.append("Active Alerts:")
            for alert in activeAlerts {
                lines.append("- \(alert)")
            }
        }

        let recentProblemsWindowSeconds: TimeInterval = 15 * 60
        let recentProblems = runtimeLog.recentProblemSummaries(
            since: date.addingTimeInterval(-recentProblemsWindowSeconds)
        )
        if recentProblems.isEmpty {
            lines.append("Recent Alerts: none")
        } else {
            lines.append("Recent Alerts (last 15m, deduped):")
            for entry in recentProblems {
                lines.append("- \(entry.renderedLine)")
            }
        }

        if notableCourts.isEmpty {
            lines.append("Notable Courts: none")
        } else {
            lines.append("Notable Courts:")
            for court in notableCourts.prefix(5) {
                var details: [String] = [
                    court.status,
                    "queue \(court.queueCount)"
                ]
                if let activeIndex = court.activeIndex {
                    details.append("active \(activeIndex + 1)")
                }
                if let currentMatch = court.currentMatch {
                    details.append("match \(currentMatch)")
                }
                if let lastPollSecondsAgo = court.lastPollSecondsAgo {
                    details.append("last poll \(lastPollSecondsAgo)s ago")
                }
                if let errorMessage = court.errorMessage, !errorMessage.isEmpty {
                    details.append("error \(errorMessage)")
                }

                lines.append("- Court \(court.id) (\(court.name)): \(details.joined(separator: ", "))")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private func activeSupportAlerts(
        healthSnapshot: OverlayHealthSnapshot,
        courtSnapshots: [CourtDiagnosticsSnapshot]
    ) -> [String] {
        var alerts: [String] = []

        if let startupError = healthSnapshot.startupError, !startupError.isEmpty {
            alerts.append("[overlay-server] \(startupError)")
        }

        let courtSnapshotsById = Dictionary(uniqueKeysWithValues: courtSnapshots.map { ($0.id, $0) })

        for courtId in healthSnapshot.errorCourtIds.sorted() {
            if let court = courtSnapshotsById[courtId],
               let errorMessage = court.errorMessage,
               !errorMessage.isEmpty {
                if let endpoint = court.currentMatchEndpoint, !endpoint.isEmpty {
                    alerts.append("[court \(courtId)] \(errorMessage) [\(endpoint)]")
                } else {
                    alerts.append("[court \(courtId)] \(errorMessage)")
                }
            } else {
                alerts.append("[court \(courtId)] polling failed")
            }
        }

        for courtId in healthSnapshot.stalePollingCourtIds.sorted() where !healthSnapshot.errorCourtIds.contains(courtId) {
            if let court = courtSnapshotsById[courtId],
               let lastPollSecondsAgo = court.lastPollSecondsAgo {
                alerts.append("[court \(courtId)] polling stale (\(lastPollSecondsAgo)s since last poll)")
            } else {
                alerts.append("[court \(courtId)] polling stale")
            }
        }

        for court in courtSnapshots.sorted(by: { $0.id < $1.id }) {
            guard let errorMessage = court.errorMessage, !errorMessage.isEmpty else { continue }
            let prefixedMessage: String
            if let endpoint = court.currentMatchEndpoint, !endpoint.isEmpty {
                prefixedMessage = "[court \(court.id)] \(errorMessage) [\(endpoint)]"
            } else {
                prefixedMessage = "[court \(court.id)] \(errorMessage)"
            }
            alerts.append(prefixedMessage)
        }

        if healthSnapshot.signalREnabled && signalRStatus.degradesHealthWhenEnabled {
            alerts.append("[signalr] \(healthSnapshot.signalRStatus)")
        }

        if !healthSnapshot.signalRMutationFallbackCourts.isEmpty {
            alerts.append("[signalr] fallback polling active for courts \(healthSnapshot.signalRMutationFallbackCourts.map(String.init).joined(separator: ", "))")
        }

        return dedupeStringsPreservingOrder(alerts)
    }

    private func endpointSummary(for url: URL) -> String {
        if let query = url.query, !query.isEmpty {
            return "\(url.path)?\(query)"
        }
        return url.path
    }

    private func dedupeStringsPreservingOrder(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []

        for item in items where seen.insert(item).inserted {
            result.append(item)
        }

        return result
    }

    func exportDiagnosticsBundle(
        to destinationURL: URL,
        runtimeLog: RuntimeLogStore = .shared
    ) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            webSocketHub.appViewModel = self
            let healthSnapshot = webSocketHub.currentHealthSnapshot(port: appSettings.serverPort)

            let manifest = DiagnosticsManifest(
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                appVersion: AppConfig.version,
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                runtimeLogPath: runtimeLog.logFilePath,
                serverRunning: serverRunning,
                signalRStatus: signalRStatus.displayLabel,
                courtCount: healthSnapshot.courtCount
            )

            let courtSnapshots = currentCourtDiagnosticsSnapshots()

            let attachments = [
                RuntimeLogStore.Attachment(
                    fileName: "settings.json",
                    data: try encoder.encode(appSettings)
                ),
                RuntimeLogStore.Attachment(
                    fileName: "court-state.json",
                    data: try encoder.encode(courtSnapshots)
                ),
                RuntimeLogStore.Attachment(
                    fileName: "health.json",
                    data: try encoder.encode(healthSnapshot)
                ),
                RuntimeLogStore.Attachment(
                    fileName: "support-summary.txt",
                    data: Data(supportSummaryText(runtimeLog: runtimeLog).utf8)
                ),
                RuntimeLogStore.Attachment(
                    fileName: "scanner-logs.txt",
                    data: Data(scannerLogExportText().utf8)
                )
            ]

            try runtimeLog.exportDiagnosticsBundle(
                to: destinationURL,
                manifest: manifest,
                attachments: attachments
            )
            runtimeLog.log(.info, subsystem: "operator", message: "exported diagnostics bundle to \(destinationURL.lastPathComponent)")
        } catch {
            runtimeLog.log(.warning, subsystem: "operator", message: "diagnostics export failed: \(error.localizedDescription)")
            throw error
        }
    }

    func exportDiagnosticsBundleToDefaultLocation(
        runtimeLog: RuntimeLogStore = .shared,
        date: Date = Date()
    ) throws -> URL {
        let exportsDirectory: URL = {
            let logsDirectory = runtimeLog.logFileURL.deletingLastPathComponent()
            if logsDirectory.lastPathComponent == "Logs" {
                let appSupportRoot = logsDirectory.deletingLastPathComponent()
                let exportsURL = appSupportRoot.appendingPathComponent("Archives", isDirectory: true)
                try? FileManager.default.createDirectory(at: exportsURL, withIntermediateDirectories: true)
                return exportsURL
            }
            return RuntimeLogStore.defaultExportsDirectory()
        }()

        let destinationURL = exportsDirectory.appendingPathComponent(suggestedDiagnosticsBundleFilename(date: date))
        try exportDiagnosticsBundle(to: destinationURL, runtimeLog: runtimeLog)
        return destinationURL
    }
    
    // MARK: - Watchdog

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkPollingHealth() }
        }
        if let t = watchdogTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func currentCourtDiagnosticsSnapshots(referenceDate: Date = Date()) -> [CourtDiagnosticsSnapshot] {
        courts.map { court in
            CourtDiagnosticsSnapshot(
                id: court.id,
                name: court.displayName,
                status: court.status.rawValue,
                currentMatch: court.currentMatch?.matchNumber,
                currentMatchEndpoint: court.currentMatch.map { endpointSummary(for: $0.apiURL) },
                queueCount: court.queue.count,
                activeIndex: court.activeIndex,
                overlayURL: overlayURL(for: court.id),
                errorMessage: court.errorMessage,
                lastPollSecondsAgo: court.lastPollTime.map { Int(referenceDate.timeIntervalSince($0)) }
            )
        }
    }

    private func checkPollingHealth() async {
        let activePollingCourtIds = courts
            .filter { $0.status.isPolling }
            .map(\.id)

        if !activePollingCourtIds.isEmpty && (!webSocketHub.isRunning || webSocketHub.startupError != nil) {
            let reason = "overlay server unavailable while polling active on courts \(activePollingCourtIds)"
            runtimeLog.log(
                .warning,
                subsystem: "polling-watchdog",
                message: "\(reason), attempting restart"
            )
            let didRestartServer = await ensureServicesRunning()
            if !didRestartServer {
                runtimeLog.log(
                    .error,
                    subsystem: "polling-watchdog",
                    message: "overlay server restart failed while polling active on courts \(activePollingCourtIds)"
                )
                return
            }
            recordWatchdogRecovery(reason: reason)
        }

        for court in courts where court.status.isPolling {
            if let lastPoll = court.lastPollTime, Date().timeIntervalSince(lastPoll) > 30 {
                runtimeLog.log(.warning, subsystem: "polling-watchdog", message: "court \(court.id) stale, restarting polling")
                pollingTimers[court.id]?.invalidate()
                pollingTimers[court.id] = nil
                pollsInFlight.remove(court.id)
                startPolling(for: court.id)
                recordWatchdogRecovery(reason: "court \(court.id) polling stale")
            }
        }
    }

    private func recordWatchdogRecovery(reason: String, at date: Date = Date()) {
        watchdogRecoveryCount += 1
        lastWatchdogRecoveryAt = date
        lastWatchdogRecoveryReason = reason
        runtimeLog.log(.info, subsystem: "polling-watchdog", message: "watchdog recovery succeeded: \(reason)")
    }

    // MARK: - Private Methods
    
    private func pollOnce(_ courtId: Int) async {
        guard let idx = courtIndex(for: courtId),
              courts[idx].status != .idle else {
            stopPolling(for: courtId)
            return
        }
        let now = Date()

        // Prevent overlapping poll cycles for the same court when network calls run long.
        guard !pollsInFlight.contains(courtId) else { return }
        pollsInFlight.insert(courtId)
        defer { pollsInFlight.remove(courtId) }
        
        guard let activeIdx = courts[idx].activeIndex,
              activeIdx < courts[idx].queue.count else {
            return
        }
        
        let matchItem = courts[idx].queue[activeIdx]
        let useSignalRPrimary = shouldUseSignalRPrimary(for: courtId)

        if useSignalRPrimary && shouldFallbackToPollingDueToSignalRMutationQuietness(courtId: courtId, now: now) {
            markSignalRMutationFallback(for: courtId, at: now)
        }

        if useSignalRPrimary && shouldSkipScorePollForSignalR(courtId: courtId, now: now) {
            await runSignalRReconciliationMaintenance(for: courtId)
            return
        }
        
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
            
            let didAdvance = await applySnapshotUpdate(
                courtId: courtId,
                snapshot: snapshot,
                matchItem: matchItem,
                allowStaleAdvance: true
            )
            if didAdvance {
                if let writeIdx = courtIndex(for: courtId) {
                    courts[writeIdx].lastPollTime = Date()
                    courts[writeIdx].errorMessage = nil
                }
                return
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
                    runtimeLog.log(
                        .info,
                        subsystem: "queue-metadata",
                        message: "updated current match teams for court \(courtId): \(snapshot.team1Name) vs \(snapshot.team2Name)"
                    )
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

            // Periodic hydrate re-fetch to resolve TBD bracket names (every 60s per division)
            await refreshHydrateIfNeeded(for: courtId)

            if let writeIdx = courtIndex(for: courtId) {
                courts[writeIdx].lastPollTime = Date()
                courts[writeIdx].errorMessage = nil
            }
            clearPlaceholderSuppressionLogState(for: courtId)
            clearPollFailureLogState(for: courtId)
            lastSignalRReconcileAt[courtId] = Date()
            // Only save if meaningful state changed (not just lastPollTime)

        } catch {
            let failure = classifyPollFailure(error, for: matchItem)
            if let writeIdx = courtIndex(for: courtId) {
                courts[writeIdx].lastPollTime = Date()
                if case .suppressedPlaceholder = failure {
                    courts[writeIdx].errorMessage = nil
                    if courts[writeIdx].status.isPolling {
                        courts[writeIdx].status = .waiting
                    }
                } else {
                    courts[writeIdx].errorMessage = failure.operatorMessage
                }
            }
            // Don't change to error status on single failure
            if case .suppressedPlaceholder = failure {
                clearPollFailureLogState(for: courtId)
                if shouldLogSuppressedPollError(for: courtId, matchItem: matchItem) {
                    runtimeLog.log(
                        .info,
                        subsystem: "polling",
                        message: "suppressed placeholder poll error for court \(courtId): \(matchItem.apiURL.absoluteString)"
                    )
                }
            } else {
                let fingerprint = "\(failure.logDetail) [\(endpointSummary(for: matchItem.apiURL))]"
                if let suppressedCount = preparePollFailureLog(for: courtId, fingerprint: fingerprint) {
                    let repeatSuffix = suppressedCount > 0
                        ? " (suppressed \(suppressedCount) duplicate log\(suppressedCount == 1 ? "" : "s"))"
                        : ""
                    runtimeLog.log(
                        .warning,
                        subsystem: "polling",
                        message: "poll error for court \(courtId): \(fingerprint)\(repeatSuffix)"
                    )
                }
            }
            lastSignalRReconcileAt[courtId] = Date()
        }
    }

    private func shouldUseSignalRPrimary(for courtId: Int) -> Bool {
        let isSignalRReady = signalRStatus == .connected && appSettings.signalREnabled
        if !isSignalRReady { return false }
        return webSocketHub.isRunning && !(webSocketHub.startupError ?? "").contains("failed")
    }
    
    private func shouldSkipScorePollForSignalR(courtId: Int, now: Date = Date()) -> Bool {
        let reconcileInterval = NetworkConstants.signalRReconcilePollInterval
        let lastReconcile = lastSignalRReconcileAt[courtId] ?? .distantPast

        if now.timeIntervalSince(lastReconcile) < reconcileInterval {
            return true
        }

        guard let lastMutationAt = lastSignalRMutationAt[courtId] else { return false }
        return now.timeIntervalSince(lastMutationAt) < reconcileInterval
    }

    private func shouldFallbackToPollingDueToSignalRMutationQuietness(
        courtId: Int,
        now: Date = Date()
    ) -> Bool {
        guard let lastMutationAt = lastSignalRMutationAt[courtId] else {
            return false
        }

        guard now.timeIntervalSince(lastMutationAt) >= NetworkConstants.signalRMutationFallbackTimeout else {
            return false
        }

        let lastFallback = lastSignalRMutationFallbackAt[courtId] ?? .distantPast
        guard now.timeIntervalSince(lastFallback) >= NetworkConstants.signalRMutationFallbackCooldown else {
            return false
        }

        return true
    }

    private func markSignalRMutationFallback(for courtId: Int, at date: Date) {
        lastSignalRMutationFallbackAt[courtId] = date
        signalRMutationFallbackCourts.insert(courtId)
        signalRMutationFallbackAttemptsByCourt[courtId, default: 0] += 1
    }

    private func clearSignalRMutationFallbackState(for courtId: Int) {
        lastSignalRMutationFallbackAt.removeValue(forKey: courtId)
        signalRMutationFallbackCourts.remove(courtId)
        signalRMutationFallbackAttemptsByCourt.removeValue(forKey: courtId)
    }

    func currentSignalRMutationFallbackSnapshot() -> (count: Int, courts: [Int]) {
        let courts = signalRMutationFallbackCourts.sorted()
        let count = courts.reduce(0) { partialResult, courtId in
            partialResult + (signalRMutationFallbackAttemptsByCourt[courtId] ?? 0)
        }
        return (count: count, courts: courts)
    }
    
    private func runSignalRReconciliationMaintenance(for courtId: Int) async {
        guard let idx = courtIndex(for: courtId),
              courts[idx].status != .idle else { return }
        
        let now = Date()
        lastSignalRReconcileAt[courtId] = now
        
        // Keep polling loop healthy for UI/health metrics while trusting SignalR for scoring.
        if let writeIdx = courtIndex(for: courtId) {
            courts[writeIdx].lastPollTime = now
            courts[writeIdx].errorMessage = nil
        }
        
        // Avoid unnecessary network load; run queued metadata updates every 15s.
        let lastRefresh = lastQueueRefreshTimes[courtId] ?? .distantPast
        if now.timeIntervalSince(lastRefresh) > 15 {
            await refreshQueueMetadata(for: courtId)
            lastQueueRefreshTimes[courtId] = now
        }
        
        if now.timeIntervalSince(lastCourtChangeCheck) > 60 {
            await checkForCourtChanges()
            lastCourtChangeCheck = now
        }

        await refreshHydrateIfNeeded(for: courtId)
        
        clearPollFailureLogState(for: courtId)
        clearPlaceholderSuppressionLogState(for: courtId)
    }

    private func scannerLogExportText() -> String {
        guard !scannerViewModel.scanLogs.isEmpty else {
            return "No scanner log entries\n"
        }

        return scannerViewModel.scanLogs.map { entry in
            "[\(entry.timeDisplay)] \(entry.type.icon) \(entry.message)"
        }
        .joined(separator: "\n") + "\n"
    }

    private func classifyPollFailure(_ error: Error, for match: MatchItem) -> PollFailureClassification {
        if case APIError.httpError(let statusCode) = error,
           match.isUnresolvedPoolPlaceholder,
           statusCode == 404 || statusCode == 500 {
            return .suppressedPlaceholder(statusCode: statusCode)
        }

        if case APIError.httpError(let statusCode) = error {
            switch statusCode {
            case 401:
                return .authenticationFailed(statusCode: statusCode)
            case 403:
                return .accessForbidden(statusCode: statusCode)
            case 404:
                return .endpointMissing(statusCode: statusCode)
            case 429:
                return .rateLimited(statusCode: statusCode)
            case 500...599:
                return .upstreamUnavailable(statusCode: statusCode)
            default:
                return .unknown(message: error.localizedDescription)
            }
        }

        if case APIError.invalidResponse = error {
            return .invalidResponse
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timedOut
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return .networkUnavailable
            default:
                return .transport(message: urlError.localizedDescription)
            }
        }

        return .unknown(message: error.localizedDescription)
    }

    private func shouldLogSuppressedPollError(for courtId: Int, matchItem: MatchItem, now: Date = Date()) -> Bool {
        let url = matchItem.apiURL.absoluteString
        if let lastLoggedAt = placeholderSuppressionLogTimes[courtId]?[url],
           now.timeIntervalSince(lastLoggedAt) < Self.placeholderSuppressionLogInterval {
            return false
        }

        var logTimes = placeholderSuppressionLogTimes[courtId] ?? [:]
        logTimes[url] = now
        placeholderSuppressionLogTimes[courtId] = logTimes
        return true
    }

    private func shouldLogSuppressedQueueMetadataError(for courtId: Int, matchItem: MatchItem, now: Date = Date()) -> Bool {
        let url = matchItem.apiURL.absoluteString
        if let lastLoggedAt = queueMetadataSuppressionLogTimes[courtId]?[url],
           now.timeIntervalSince(lastLoggedAt) < Self.placeholderSuppressionLogInterval {
            return false
        }

        var logTimes = queueMetadataSuppressionLogTimes[courtId] ?? [:]
        logTimes[url] = now
        queueMetadataSuppressionLogTimes[courtId] = logTimes
        return true
    }

    private func clearPlaceholderSuppressionLogState(for courtId: Int) {
        placeholderSuppressionLogTimes[courtId] = nil
    }

    private func preparePollFailureLog(
        for courtId: Int,
        fingerprint: String,
        now: Date = Date()
    ) -> Int? {
        guard var state = pollFailureLogStates[courtId] else {
            pollFailureLogStates[courtId] = PollFailureLogState(
                fingerprint: fingerprint,
                firstFailureAt: now,
                lastFailureAt: now,
                consecutiveFailures: 1,
                lastLoggedAt: now,
                suppressedCount: 0
            )
            return 0
        }

        guard state.fingerprint == fingerprint else {
            pollFailureLogStates[courtId] = PollFailureLogState(
                fingerprint: fingerprint,
                firstFailureAt: now,
                lastFailureAt: now,
                consecutiveFailures: 1,
                lastLoggedAt: now,
                suppressedCount: 0
            )
            return 0
        }

        state.lastFailureAt = now
        state.consecutiveFailures += 1

        if now.timeIntervalSince(state.lastLoggedAt) < Self.pollFailureLogInterval {
            state.suppressedCount += 1
            pollFailureLogStates[courtId] = state
            return nil
        }

        let suppressedCount = state.suppressedCount
        state.lastLoggedAt = now
        state.suppressedCount = 0
        pollFailureLogStates[courtId] = state
        return suppressedCount
    }

    private func clearPollFailureLogState(for courtId: Int) {
        guard let state = pollFailureLogStates.removeValue(forKey: courtId) else { return }
        let degradedSeconds = max(1, Int(state.lastFailureAt.timeIntervalSince(state.firstFailureAt)))
        runtimeLog.log(
            .info,
            subsystem: "polling",
            message: "court \(courtId) polling recovered from \(state.fingerprint) after \(state.consecutiveFailures) failure\(state.consecutiveFailures == 1 ? "" : "s") over \(degradedSeconds)s"
        )
    }

    private func clearQueueMetadataSuppressionLogState(for courtId: Int, matchItem: MatchItem? = nil) {
        guard let matchItem else {
            queueMetadataSuppressionLogTimes[courtId] = nil
            return
        }

        let url = matchItem.apiURL.absoluteString
        guard var logTimes = queueMetadataSuppressionLogTimes[courtId] else { return }
        logTimes.removeValue(forKey: url)
        queueMetadataSuppressionLogTimes[courtId] = logTimes.isEmpty ? nil : logTimes
    }

    private func clearSuppressionLogState(for courtId: Int) {
        clearPlaceholderSuppressionLogState(for: courtId)
        clearQueueMetadataSuppressionLogState(for: courtId)
        pollFailureLogStates[courtId] = nil
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

    private func isMatchURLClaimedByAnotherCourt(_ candidateMatch: MatchItem, for courtId: Int) -> Bool {
        for court in courts where court.id != courtId {
            guard let activeIdx = court.activeIndex,
                  court.queue.indices.contains(activeIdx) else {
                continue
            }

            let activeMatch = court.queue[activeIdx]
            if activeMatch.apiURL == candidateMatch.apiURL || matchesRepresentSameContest(activeMatch, candidateMatch) {
                return true
            }
        }
        return false
    }

    private func defaultQueueArbitrationReason(for activeIndex: Int?) -> QueueArbitrationReason {
        guard let activeIndex else { return .queueDefault }
        return activeIndex == 0 ? .queueDefault : .manual
    }

    private func currentQueueArbitrationReason(for courtId: Int, activeIndex: Int?) -> QueueArbitrationReason {
        queueArbitrationReasonByCourt[courtId] ?? defaultQueueArbitrationReason(for: activeIndex)
    }

    private func noteQueueArbitration(_ courtId: Int, reason: QueueArbitrationReason, message: String) {
        let fingerprint = "\(reason.rawValue):\(message)"
        guard lastQueueArbitrationNoteByCourt[courtId] != fingerprint else { return }
        lastQueueArbitrationNoteByCourt[courtId] = fingerprint
        runtimeLog.log(.info, subsystem: "queue", message: message)
    }

    private func otherCourtsHaveCredibleLiveClaims(excluding courtId: Int) -> Bool {
        for court in courts where court.id != courtId {
            if court.status == .live || observedActiveScoring[court.id] == true {
                return true
            }
            if let snapshot = court.lastSnapshot, isMatchActive(snapshot) {
                return true
            }
        }
        return false
    }

    private func smartSwitchCandidateStrength(for snapshot: ScoreSnapshot) -> Int? {
        guard isMatchActive(snapshot) else { return nil }

        let lowercasedStatus = snapshot.status.lowercased()
        let hasExplicitLiveStatus =
            lowercasedStatus.contains("live")
            || lowercasedStatus.contains("progress")
            || lowercasedStatus.contains("playing")
        let totalPoints = snapshot.team1Score + snapshot.team2Score
        let hasCompletedSet = snapshot.setHistory.contains(where: \.isComplete)
        let hasMultiSetEvidence = snapshot.setNumber > 1 || snapshot.setHistory.count > 1

        if hasCompletedSet || hasMultiSetEvidence || totalPoints >= 12 {
            return 3
        }

        return (hasExplicitLiveStatus || totalPoints >= 4) ? 2 : 1
    }
    
    /// Smart Queue Switch: Check if current match is 0-0 but another queue match has active scoring.
    /// If so, auto-switch to the active match to prioritize live content.
    private func checkForSmartQueueSwitch(courtId: Int, currentSnapshot: ScoreSnapshot) async -> Bool {
        guard let idx = courtIndex(for: courtId) else { return false }
        guard let activeIdx = courts[idx].activeIndex else { return false }
        let currentReason = currentQueueArbitrationReason(for: courtId, activeIndex: activeIdx)
        let bypassEligible =
            activeIdx == 0
            && !isMatchActive(currentSnapshot)
            && !(observedActiveScoring[courtId] ?? false)
        let competingLiveClaims = otherCourtsHaveCredibleLiveClaims(excluding: courtId)
        let currentHasResidualEvidence =
            (currentSnapshot.team1Score + currentSnapshot.team2Score) > 0
            || !currentSnapshot.setHistory.isEmpty

        if let fallbackStart = smartSwitchFallbackOriginIndex[courtId],
           activeIdx > 0,
           !isMatchActive(currentSnapshot),
           !currentHasResidualEvidence,
           let currentIdx = courtIndex(for: courtId) {
            let canonicalIdx = await firstNonFinalQueueIndex(courtId: courtId, startingAt: fallbackStart)
            if canonicalIdx < activeIdx,
               canonicalIdx < courts[currentIdx].queue.count {
                let revertReason: QueueArbitrationReason = .laterLiveBypass
                noteQueueArbitration(
                    courtId,
                    reason: revertReason,
                    message: "later live bypass reverted on court \(courtId); returned from queue index \(activeIdx) to \(canonicalIdx)"
                )
                smartSwitchFallbackOriginIndex.removeValue(forKey: courtId)
                smartSwitchedMatchID.removeValue(forKey: courtId)
                pendingSmartSwitchCandidate.removeValue(forKey: courtId)
                queueArbitrationReasonByCourt[courtId] = defaultQueueArbitrationReason(for: canonicalIdx)
                courts[currentIdx].activeIndex = canonicalIdx
                courts[currentIdx].lastSnapshot = nil
                courts[currentIdx].status = .waiting
                courts[currentIdx].liveSince = nil
                courts[currentIdx].finishedAt = nil
                observedActiveScoring[courtId] = false
                lastScoreChangeTime[courtId] = nil
                lastScoreSnapshot[courtId] = nil
                lastServeTeam.removeValue(forKey: courtId)
                return true
            }
        }

        // Only smart-switch if the current match is not actively in progress.
        guard !isMatchActive(currentSnapshot) else {
            pendingSmartSwitchCandidate.removeValue(forKey: courtId)
            if currentReason == .ambiguousHold {
                queueArbitrationReasonByCourt[courtId] = defaultQueueArbitrationReason(for: activeIdx)
            }
            return false
        }

        // Don't switch if we've been live on this match (liveSince set)
        if courts[idx].liveSince != nil,
           currentReason != .laterLiveBypass,
           smartSwitchFallbackOriginIndex[courtId] == nil {
            pendingSmartSwitchCandidate.removeValue(forKey: courtId)
            return false
        }

        // The default queue head can be scanned less often, but once we have
        // smart-switched away from it we need to re-evaluate every cycle so an
        // accidental later score cannot pin the wrong match on air.
        if activeIdx == 0,
           pendingSmartSwitchCandidate[courtId] == nil,
           Date().timeIntervalSince(lastSmartSwitchCheck[courtId] ?? .distantPast) < 30 {
            return false
        }
        lastSmartSwitchCheck[courtId] = Date()

        // Scan queue in parallel for any match with active scoring
        let queue = courts[idx].queue
        let result: (index: Int, strength: Int)? = await withTaskGroup(of: (Int, Int?).self) { group in
            for (queueIdx, match) in queue.enumerated() {
                guard queueIdx != activeIdx else { continue }
                guard !isMatchURLClaimedByAnotherCourt(match, for: courtId) else { continue }
                group.addTask { [scoreCache] in
                    guard let data = try? await scoreCache.get(match.apiURL) else {
                        return (queueIdx, nil)
                    }
                    let snapshot = await MainActor.run { self.normalizeData(data, courtId: 0, currentMatch: match) }
                    let strength = await MainActor.run { self.smartSwitchCandidateStrength(for: snapshot) }
                    return (queueIdx, strength)
                }
            }
            var bestCandidate: (index: Int, strength: Int)?
            for await (queueIdx, strength) in group {
                guard let strength else { continue }
                if let currentBest = bestCandidate {
                    if queueIdx < currentBest.index {
                        bestCandidate = (queueIdx, strength)
                    } else if queueIdx == currentBest.index {
                        bestCandidate = (queueIdx, max(currentBest.strength, strength))
                    }
                } else {
                    bestCandidate = (queueIdx, strength)
                }
            }
            return bestCandidate
        }

        if let candidate = result {
            let now = Date()

            if bypassEligible {
                if candidate.strength <= 1 {
                    pendingSmartSwitchCandidate.removeValue(forKey: courtId)
                    queueArbitrationReasonByCourt[courtId] = competingLiveClaims ? .ambiguousHold : .queueDefault
                    noteQueueArbitration(
                        courtId,
                        reason: queueArbitrationReasonByCourt[courtId] ?? .queueDefault,
                        message: "no-score queue head held on court \(courtId); later match evidence at index \(candidate.index) is too weak"
                    )
                    return false
                }

                if candidate.strength == 2 {
                    let confirmationWindow = weakSmartSwitchConfirmationWindow * (competingLiveClaims ? 2.0 : 1.5)
                    if let pending = pendingSmartSwitchCandidate[courtId],
                       pending.queueIndex == candidate.index,
                       now.timeIntervalSince(pending.firstSeenAt) >= confirmationWindow {
                        pendingSmartSwitchCandidate.removeValue(forKey: courtId)
                    } else {
                        let firstSeenAt = pendingSmartSwitchCandidate[courtId]?.queueIndex == candidate.index
                            ? pendingSmartSwitchCandidate[courtId]!.firstSeenAt
                            : now
                        pendingSmartSwitchCandidate[courtId] = (queueIndex: candidate.index, firstSeenAt: firstSeenAt)
                        queueArbitrationReasonByCourt[courtId] = competingLiveClaims ? .ambiguousHold : .queueDefault
                        noteQueueArbitration(
                            courtId,
                            reason: queueArbitrationReasonByCourt[courtId] ?? .queueDefault,
                            message: competingLiveClaims
                                ? "ambiguous hold on court \(courtId); waiting for stronger later-live evidence at index \(candidate.index)"
                                : "no-score queue head held on court \(courtId); waiting to confirm later live evidence at index \(candidate.index)"
                        )
                        return false
                    }
                } else {
                    pendingSmartSwitchCandidate.removeValue(forKey: courtId)
                }
            } else {
                if currentReason == .manual && candidate.strength < 3 {
                    pendingSmartSwitchCandidate.removeValue(forKey: courtId)
                    noteQueueArbitration(
                        courtId,
                        reason: .manual,
                        message: "manual selection held on court \(courtId); ignored weak auto-switch candidate at index \(candidate.index)"
                    )
                    return false
                }

                if candidate.strength == 1 {
                    if let pending = pendingSmartSwitchCandidate[courtId],
                       pending.queueIndex == candidate.index,
                       now.timeIntervalSince(pending.firstSeenAt) >= weakSmartSwitchConfirmationWindow {
                        pendingSmartSwitchCandidate.removeValue(forKey: courtId)
                    } else {
                        let firstSeenAt = pendingSmartSwitchCandidate[courtId]?.queueIndex == candidate.index
                            ? pendingSmartSwitchCandidate[courtId]!.firstSeenAt
                            : now
                        pendingSmartSwitchCandidate[courtId] = (queueIndex: candidate.index, firstSeenAt: firstSeenAt)
                        return false
                    }
                } else {
                    pendingSmartSwitchCandidate.removeValue(forKey: courtId)
                }
            }
        } else {
            if smartSwitchFallbackOriginIndex[courtId] != nil,
               let currentIdx = courtIndex(for: courtId),
               let fallbackStart = smartSwitchFallbackOriginIndex[courtId] {
                let canonicalIdx = await firstNonFinalQueueIndex(courtId: courtId, startingAt: fallbackStart)
                guard canonicalIdx < activeIdx,
                      canonicalIdx < courts[currentIdx].queue.count else {
                    pendingSmartSwitchCandidate.removeValue(forKey: courtId)
                    if bypassEligible {
                        queueArbitrationReasonByCourt[courtId] = .queueDefault
                        noteQueueArbitration(
                            courtId,
                            reason: .queueDefault,
                            message: "no-score queue head held on court \(courtId); no later live evidence"
                        )
                    } else if currentReason == .ambiguousHold {
                        queueArbitrationReasonByCourt[courtId] = defaultQueueArbitrationReason(for: activeIdx)
                    }
                    return false
                }
                let revertReason: QueueArbitrationReason = .laterLiveBypass
                noteQueueArbitration(
                    courtId,
                    reason: revertReason,
                    message: "later live bypass reverted on court \(courtId); returned from queue index \(activeIdx) to \(canonicalIdx)"
                )
                smartSwitchFallbackOriginIndex.removeValue(forKey: courtId)
                smartSwitchedMatchID.removeValue(forKey: courtId)
                pendingSmartSwitchCandidate.removeValue(forKey: courtId)
                queueArbitrationReasonByCourt[courtId] = defaultQueueArbitrationReason(for: canonicalIdx)
                courts[currentIdx].activeIndex = canonicalIdx
                courts[currentIdx].lastSnapshot = nil
                courts[currentIdx].status = .waiting
                courts[currentIdx].liveSince = nil
                courts[currentIdx].finishedAt = nil
                observedActiveScoring[courtId] = false
                lastScoreChangeTime[courtId] = nil
                lastScoreSnapshot[courtId] = nil
                lastServeTeam.removeValue(forKey: courtId)
                return true
            }
            pendingSmartSwitchCandidate.removeValue(forKey: courtId)
            if bypassEligible {
                queueArbitrationReasonByCourt[courtId] = .queueDefault
                noteQueueArbitration(
                    courtId,
                    reason: .queueDefault,
                    message: "no-score queue head held on court \(courtId); no later live evidence"
                )
            } else if currentReason == .ambiguousHold {
                queueArbitrationReasonByCourt[courtId] = defaultQueueArbitrationReason(for: activeIdx)
            }
        }

        if let switchIdx = result?.index,
           let currentIdx = courtIndex(for: courtId),
           switchIdx < courts[currentIdx].queue.count {
            smartSwitchFallbackOriginIndex[courtId] = smartSwitchFallbackOriginIndex[courtId] ?? activeIdx
            smartSwitchedMatchID[courtId] = courts[currentIdx].queue[switchIdx].id
            let switchReason: QueueArbitrationReason = bypassEligible ? .laterLiveBypass : .smartSwitch
            queueArbitrationReasonByCourt[courtId] = switchReason
            noteQueueArbitration(
                courtId,
                reason: switchReason,
                message: bypassEligible
                    ? "later live bypass accepted on court \(courtId); switched from queue index \(activeIdx) to \(switchIdx)"
                    : "smart-switched court \(courtId) from queue index \(activeIdx) to live match at index \(switchIdx)"
            )
            courts[currentIdx].activeIndex = switchIdx
            courts[currentIdx].lastSnapshot = nil
            courts[currentIdx].status = .waiting
            courts[currentIdx].liveSince = nil
            courts[currentIdx].finishedAt = nil
            observedActiveScoring[courtId] = false
            lastScoreChangeTime[courtId] = nil
            lastScoreSnapshot[courtId] = nil
            lastServeTeam.removeValue(forKey: courtId)
            return true
        }

        guard activeIdx > 0,
              let fallbackStart = smartSwitchFallbackOriginIndex[courtId],
              let currentIdx = courtIndex(for: courtId),
              activeIdx < courts[currentIdx].queue.count,
              smartSwitchedMatchID[courtId] == courts[currentIdx].queue[activeIdx].id else {
            return false
        }

        let canonicalIdx = await firstNonFinalQueueIndex(courtId: courtId, startingAt: fallbackStart)
        guard canonicalIdx < activeIdx,
              canonicalIdx < courts[currentIdx].queue.count else {
            return false
        }

        let revertReason: QueueArbitrationReason = queueArbitrationReasonByCourt[courtId] == .laterLiveBypass ? .laterLiveBypass : .smartSwitch
        noteQueueArbitration(
            courtId,
            reason: revertReason,
            message: revertReason == .laterLiveBypass
                ? "later live bypass reverted on court \(courtId); returned from queue index \(activeIdx) to \(canonicalIdx)"
                : "smart-switch reverted court \(courtId) from queue index \(activeIdx) to queue index \(canonicalIdx)"
        )
        smartSwitchFallbackOriginIndex.removeValue(forKey: courtId)
        smartSwitchedMatchID.removeValue(forKey: courtId)
        pendingSmartSwitchCandidate.removeValue(forKey: courtId)
        queueArbitrationReasonByCourt[courtId] = defaultQueueArbitrationReason(for: canonicalIdx)
        courts[currentIdx].activeIndex = canonicalIdx
        courts[currentIdx].lastSnapshot = nil
        courts[currentIdx].status = .waiting
        courts[currentIdx].liveSince = nil
        courts[currentIdx].finishedAt = nil
        observedActiveScoring[courtId] = false
        lastScoreChangeTime[courtId] = nil
        lastScoreSnapshot[courtId] = nil
        lastServeTeam.removeValue(forKey: courtId)
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

        runtimeLog.log(.info, subsystem: "queue", message: "preflight advanced court \(courtId) to match \(targetIdx + 1)")
    }

    // MARK: - Hydrate Re-fetch

    /// Periodically re-fetch the division hydrate endpoint to resolve TBD bracket team names.
    /// The hydrate endpoint returns the full division tree including resolved bracket slots,
    /// which updates faster than individual vMix endpoints.
    private func refreshHydrateIfNeeded(for courtId: Int, force: Bool = false) async {
        guard let idx = courtIndex(for: courtId) else { return }

        // Collect unique division IDs from all queued matches
        let divisionIds = Set(courts[idx].queue.compactMap { $0.divisionId })
        guard !divisionIds.isEmpty else { return }

        let hydrateBase = "https://volleyballlife-api-dot-net-8.azurewebsites.net/division"

        for divId in divisionIds {
            let lastRefresh = lastHydrateRefresh[divId] ?? .distantPast
            guard force || Date().timeIntervalSince(lastRefresh) > Self.hydrateRefreshInterval else { continue }

            guard let url = URL(string: "\(hydrateBase)/\(divId)/hydrate") else { continue }

            do {
                let data = try await scoreCache.get(url)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let updated = applyHydrateLookup(courtId: courtId, divisionId: divId, hydrateJSON: json)
                if updated {
                    rebuildGameIdMap()
                    scheduleSave()
                }
                lastHydrateRefresh[divId] = Date()
            } catch {
                // Silently ignore — this is a best-effort optimization
            }
        }
    }

    private func applyHydrateLookup(
        courtId: Int,
        divisionId: Int,
        hydrateJSON: [String: Any]
    ) -> Bool {
        let teamLookup = Self.buildTeamLookup(from: hydrateJSON)
        let gameIdLookup = Self.buildGameIdLookup(from: hydrateJSON)
        guard !teamLookup.isEmpty || !gameIdLookup.isEmpty else { return false }
        guard let writeIdx = courtIndex(for: courtId) else { return false }

        var updated = false
        for i in 0..<courts[writeIdx].queue.count {
            let match = courts[writeIdx].queue[i]
            guard match.divisionId == divisionId else { continue }

            if let matchIdStr = extractMatchId(from: match.apiURL) {
                if let resolved = teamLookup[matchIdStr] {
                    if let t1 = resolved.team1, match.team1Name != t1 {
                        courts[writeIdx].queue[i].team1Name = t1
                        updated = true
                    }
                    if let t2 = resolved.team2, match.team2Name != t2 {
                        courts[writeIdx].queue[i].team2Name = t2
                        updated = true
                    }
                }

                if let gids = gameIdLookup[matchIdStr], match.gameIds != gids {
                    courts[writeIdx].queue[i].gameIds = gids
                    updated = true
                }
            }
        }
        return updated
    }

    /// Build a lookup of matchIdString → [gameId] from hydrate JSON.
    /// Hydrate structure: brackets[].matches[].games[].id and pools[].matches[].games[].id
    static func buildGameIdLookup(from json: [String: Any]) -> [String: [Int]] {
        var lookup: [String: [Int]] = [:]

        for match in extractHydrateMatches(from: json) {
            guard let matchId = match["id"] as? Int, matchId > 0 else { continue }
            if let games = match["games"] as? [[String: Any]] {
                let gameIds = games.compactMap { $0["id"] as? Int }.filter { $0 > 0 }
                if !gameIds.isEmpty {
                    lookup[String(matchId)] = gameIds
                }
            }
        }

        return lookup
    }

    /// Rebuild the gameId → courtId lookup from all active courts' match items.
    private func rebuildGameIdMap() {
        var newMap: [Int: Int] = [:]
        var ambiguousMap: [Int: Set<Int>] = [:]
        for court in courts where court.status.isPolling {
            guard let activeIdx = court.activeIndex,
                  activeIdx < court.queue.count else { continue }
            let match = court.queue[activeIdx]
            if let gameIds = match.gameIds {
                for gid in gameIds {
                    if let existingCourtId = newMap[gid], existingCourtId != court.id {
                        ambiguousMap[gid, default: [existingCourtId]].insert(court.id)
                        newMap.removeValue(forKey: gid)
                    } else if ambiguousMap[gid] != nil {
                        ambiguousMap[gid, default: []].insert(court.id)
                    } else {
                        newMap[gid] = court.id
                    }
                }
            }
        }
        gameIdToCourtMap = newMap
        ambiguousGameIdToCourtIds = ambiguousMap
    }

    /// Build a lookup of matchId → (team1, team2) from hydrate JSON
    static func buildTeamLookup(from json: [String: Any]) -> [String: (team1: String?, team2: String?)] {
        var lookup: [String: (team1: String?, team2: String?)] = [:]

        // Parse teams array
        var teamNames: [Int: String] = [:]
        if let teams = json["teams"] as? [[String: Any]] {
            for team in teams {
                if let id = team["id"] as? Int,
                   let players = team["players"] as? [[String: Any]] {
                    let names = players.compactMap { p -> String? in
                        let first = p["firstName"] as? String ?? ""
                        let last = p["lastName"] as? String ?? ""
                        return last.isEmpty ? nil : "\(first) \(last)".trimmingCharacters(in: .whitespaces)
                    }
                    if !names.isEmpty {
                        teamNames[id] = names.joined(separator: " / ")
                    }
                }
            }
        }

        for match in extractHydrateMatches(from: json) {
            guard let matchId = match["id"] as? Int, matchId > 0 else { continue }
            let homeId = extractHydrateTeamId(from: match["homeTeam"])
                ?? (match["homeTeamId"] as? Int)
            let awayId = extractHydrateTeamId(from: match["awayTeam"])
                ?? (match["awayTeamId"] as? Int)
            let t1 = homeId.flatMap { teamNames[$0] }
            let t2 = awayId.flatMap { teamNames[$0] }
            if t1 != nil || t2 != nil {
                lookup[String(matchId)] = (team1: t1, team2: t2)
            }
        }

        return lookup
    }

    static func extractHydrateMatches(from json: [String: Any]) -> [[String: Any]] {
        var matches: [[String: Any]] = []

        func appendMatches(from brackets: [[String: Any]]) {
            for bracket in brackets {
                if let bracketMatches = bracket["matches"] as? [[String: Any]] {
                    matches.append(contentsOf: bracketMatches)
                }
            }
        }

        func appendPoolMatches(from pools: [[String: Any]]) {
            for pool in pools {
                if let poolMatches = pool["matches"] as? [[String: Any]] {
                    matches.append(contentsOf: poolMatches)
                }
            }
        }

        func appendFlightPools(from flights: [[String: Any]]) {
            for flight in flights {
                if let pools = flight["pools"] as? [[String: Any]] {
                    appendPoolMatches(from: pools)
                }
            }
        }

        if let days = json["days"] as? [[String: Any]] {
            for day in days {
                if let brackets = day["brackets"] as? [[String: Any]] {
                    appendMatches(from: brackets)
                }
                if let flights = day["flights"] as? [[String: Any]] {
                    appendFlightPools(from: flights)
                }
                if let pools = day["pools"] as? [[String: Any]] {
                    appendPoolMatches(from: pools)
                }
            }
        }

        if let brackets = json["brackets"] as? [[String: Any]] {
            appendMatches(from: brackets)
        }
        if let flights = json["flights"] as? [[String: Any]] {
            appendFlightPools(from: flights)
        }
        if let pools = json["pools"] as? [[String: Any]] {
            appendPoolMatches(from: pools)
        }

        return matches
    }

    static func extractHydrateTeamId(from rawTeam: Any?) -> Int? {
        guard let team = rawTeam as? [String: Any] else {
            return nil
        }

        if let teamId = team["teamId"] as? Int, teamId > 0 {
            return teamId
        }

        return nil
    }

    /// Extract match ID from a vMix API URL like .../matches/325750/vmix...
    private func extractMatchId(from url: URL) -> String? {
        let path = url.path
        guard let range = path.range(of: #"/matches/(\d+)"#, options: .regularExpression) else { return nil }
        let match = path[range]
        let digits = match.drop(while: { !$0.isNumber })
        return String(digits)
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
                    runtimeLog.log(.warning, subsystem: "queue-metadata", message: "queue changed during metadata refresh for court \(courtId), stopping early")
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
                        runtimeLog.log(.warning, subsystem: "queue-metadata", message: "queue changed during metadata refresh for court \(courtId), stopping early")
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
                        runtimeLog.log(.info, subsystem: "queue-metadata", message: "updated queued metadata for court \(courtId) match index \(i)")
                    }
                    clearQueueMetadataSuppressionLogState(for: courtId, matchItem: match)
                } catch {
                    let failure = classifyPollFailure(error, for: match)
                    if case .suppressedPlaceholder = failure {
                        if shouldLogSuppressedQueueMetadataError(for: courtId, matchItem: match) {
                            runtimeLog.log(
                                .info,
                                subsystem: "queue-metadata",
                                message: "suppressed placeholder queue metadata refresh for court \(courtId): \(match.apiURL.absoluteString)"
                            )
                        }
                    } else {
                        runtimeLog.log(
                            .warning,
                            subsystem: "queue-metadata",
                            message: "failed to refresh queued metadata for court \(courtId): \(failure.logDetail) [\(endpointSummary(for: match.apiURL))]"
                        )
                    }
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
        runtimeLog.log(
            .warning,
            subsystem: "court-change",
            message: "\(matchLabel) moved from \(CourtNaming.defaultName(for: change.fromCourt)) to \(CourtNaming.defaultName(for: change.toCourt))"
        )

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
        
        await notificationService.sendCourtChangeAlert(event)
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

        // Pool play "play all N sets" mode: only concluded when all mandatory sets are complete
        if let setsToPlay = match?.setsToPlay {
            let completedSets = snapshot.setHistory.filter { $0.isComplete }.count
            return completedSets >= setsToPlay
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
        let configuredSetCount = max(currentMatch?.setsToPlay ?? 0, setsToWin)
        
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
        
        // Set 2
        if configuredSetCount >= 2 && (g2a_raw > 0 || g2b_raw > 0) {
            let complete = isSetComplete(g2a_raw, g2b_raw, target: pointsPerSet, cap: pointCap)
            setHistory.append(SetScore(setNumber: 2, team1Score: g2a_raw, team2Score: g2b_raw, isComplete: complete))
            if complete {
                if g2a_raw > g2b_raw { score1 += 1 } else { score2 += 1 }
            }
        }

        // Set 3 (tiebreak: use 15 or match format if lower, e.g., training to 11)
        if configuredSetCount >= 3 && (g3a_raw > 0 || g3b_raw > 0) {
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
        let completedSets = setHistory.filter(\.isComplete).count
        
        let status: String
        if let setsToPlay = currentMatch?.setsToPlay {
            if completedSets >= setsToPlay {
                status = "Final"
            } else if !setHistory.isEmpty || g1a_raw > 0 || g1b_raw > 0 {
                status = "In Progress"
            } else {
                status = "Pre-Match"
            }
        } else if won1 || won2 {
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
        var home = score?["home"] as? Int ?? 0
        var away = score?["away"] as? Int ?? 0
        
        var name1 = (dict["team1_text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty()
            ?? (dict["homeTeam"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty()
            ?? (dict["team1Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty()
            ?? currentMatch?.team1Name
            ?? "Team A"
        var name2 = (dict["team2_text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty()
            ?? (dict["awayTeam"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty()
            ?? (dict["team2Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty()
            ?? currentMatch?.team2Name
            ?? "Team B"
        var team1Seed = (dict["seed1"] as? String) ?? currentMatch?.team1Seed
        var team2Seed = (dict["seed2"] as? String) ?? currentMatch?.team2Seed

        if let currentMatch,
           normalizedIdentityComponent(name1) == normalizedIdentityComponent(currentMatch.team2Name),
           normalizedIdentityComponent(name2) == normalizedIdentityComponent(currentMatch.team1Name) {
            name1 = currentMatch.team1Name ?? name1
            name2 = currentMatch.team2Name ?? name2
            swap(&home, &away)
            swap(&team1Seed, &team2Seed)
        }
        
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
            team1Seed: team1Seed,
            team2Seed: team2Seed,
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

    private func loadConfiguration() {
        let configURL = configStore.courtsConfigURL
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

            let boundedActiveIndex: Int? = {
                guard let activeIndex = normalizedCourts[idx].activeIndex else { return nil }
                guard !normalizedCourts[idx].queue.isEmpty else { return nil }
                return min(max(0, activeIndex), normalizedCourts[idx].queue.count - 1)
            }()
            if normalizedCourts[idx].activeIndex != boundedActiveIndex {
                normalizedCourts[idx].activeIndex = boundedActiveIndex
                didNormalize = true
            }

            if normalizedCourts[idx].status != .idle
                || normalizedCourts[idx].lastSnapshot != nil
                || normalizedCourts[idx].liveSince != nil
                || normalizedCourts[idx].finishedAt != nil
                || normalizedCourts[idx].lastPollTime != nil
                || normalizedCourts[idx].errorMessage != nil {
                normalizedCourts[idx].status = .idle
                normalizedCourts[idx].lastSnapshot = nil
                normalizedCourts[idx].liveSince = nil
                normalizedCourts[idx].finishedAt = nil
                normalizedCourts[idx].lastPollTime = nil
                normalizedCourts[idx].errorMessage = nil
                didNormalize = true
            }
        }

        courts = normalizedCourts
        if didNormalize {
            saveConfigurationNow()
            runtimeLog.log(.info, subsystem: "config", message: "normalized legacy pool formats in saved queues")
        }
        runtimeLog.log(.info, subsystem: "config", message: "loaded configuration with \(courts.count) courts")
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
        let configURL = configStore.courtsConfigURL
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

    // MARK: - SignalR Lifecycle

    private func startSignalR() {
        guard signalRClient == nil else { return }
        guard let credentials = signalRCredentialsProvider() else {
            signalRStatus = .noCredentials
            return
        }
        let client = signalRClientFactory(self)
        signalRClient = client
        Task {
            await client.connect(credentials: credentials)
        }
    }

    private func stopSignalR() {
        guard let client = signalRClient else { return }
        let tournaments = Array(activeSubscriptions.keys)
        activeSubscriptions.removeAll()
        lastSignalRMutationFallbackAt.removeAll()
        signalRMutationFallbackCourts.removeAll()
        signalRMutationFallbackAttemptsByCourt.removeAll()
        Task {
            for tournamentId in tournaments {
                await client.unsubscribeFromTournament(tournamentId)
            }
            await client.disconnect()
        }
        signalRClient = nil
        signalRStatus = .disabled
    }

    private func syncSignalRSubscriptions(forceResubscribe: Bool = false) {
        Task { @MainActor [weak self] in
            await self?.refreshSignalRSubscriptions(forceResubscribe: forceResubscribe)
        }
    }

    private func refreshSignalRSubscriptions(forceResubscribe: Bool = false) async {
        guard appSettings.signalREnabled,
              signalRStatus == .connected,
              let client = signalRClient else { return }

        var desired: [Int: Set<Int>] = [:]
        for court in courts where court.status.isPolling {
            for match in court.queue {
                guard let tournamentId = match.tournamentId, let divisionId = match.divisionId else { continue }
                desired[tournamentId, default: []].insert(divisionId)
            }
        }

        let previous = activeSubscriptions
        if !forceResubscribe && desired == previous { return }

        let tournamentsToUnsubscribe = forceResubscribe
            ? Set(previous.keys)
            : Set(previous.keys).filter { desired[$0] != previous[$0] }
        for tournamentId in tournamentsToUnsubscribe {
            await client.unsubscribeFromTournament(tournamentId)
        }

        for (tournamentId, desiredDivisions) in desired {
            let shouldRefreshTournament = forceResubscribe || previous[tournamentId] != desiredDivisions
            guard shouldRefreshTournament else { continue }
            for divisionId in desiredDivisions {
                await client.subscribeToTournament(tournamentId: tournamentId, divisionId: divisionId)
            }
        }

        activeSubscriptions = desired
        if desired.isEmpty {
            runtimeLog.log(.info, subsystem: "signalr", message: "SignalR subscriptions cleared (no polling courts).")
        }
    }

    func setSignalREnabled(_ enabled: Bool) {
        appSettings.signalREnabled = enabled
        configStore.saveSettings(appSettings)
        if enabled {
            startSignalR()
        } else {
            stopSignalR()
        }
    }

    func reconnectSignalRIfNeeded() {
        guard appSettings.signalREnabled else { return }
        stopSignalR()
        startSignalR()
    }

    private static func detectRuntimeMode() -> RuntimeMode {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--uitest-mode") ? .uiTest : .live
    }

    private func loadUITestScenario() {
        for idx in courts.indices {
            courts[idx] = Court.create(id: courts[idx].id, name: CourtNaming.defaultName(for: courts[idx].id))
        }

        appSettings.autoStartPolling = false
        appSettings.signalREnabled = false

        let courtOneQueue = [
            MatchItem(
                apiURL: URL(string: "https://example.com/matches/1001/vmix")!,
                label: "1",
                team1Name: "Riley Adams / Sam Brooks",
                team2Name: "Taylor Clark / Jules Diaz",
                team1Seed: "2",
                team2Seed: "5",
                matchType: "Pool Play",
                scheduledTime: "8:00AM",
                startDate: "Sat",
                matchNumber: "1",
                courtNumber: "7",
                setsToWin: 1,
                pointsPerSet: 21,
                pointCap: 23
            ),
            MatchItem(
                apiURL: URL(string: "https://example.com/matches/1002/vmix")!,
                label: "2",
                team1Name: "Alex Ellis / Casey Frost",
                team2Name: "Jordan Gray / Parker Holt",
                team1Seed: "3",
                team2Seed: "6",
                matchType: "Pool Play",
                scheduledTime: "8:35AM",
                startDate: "Sat",
                matchNumber: "2",
                courtNumber: "7",
                setsToWin: 1,
                pointsPerSet: 21,
                pointCap: 23
            )
        ]
        replaceQueue(1, with: courtOneQueue, startIndex: 0)

        let courtTwoMatch = MatchItem(
            apiURL: URL(string: "https://example.com/matches/2001/vmix")!,
            label: "7",
            team1Name: "Morgan Ivy / Quinn James",
            team2Name: "Reese Knight / Logan Mills",
            team1Seed: "1",
            team2Seed: "4",
            matchType: "Bracket Play",
            scheduledTime: "9:15AM",
            startDate: "Sun",
            matchNumber: "7",
            courtNumber: "8",
            setsToWin: 2,
            pointsPerSet: 21
        )
        replaceQueue(2, with: [courtTwoMatch], startIndex: 0)
        if let idx = courtIndex(for: 2) {
            courts[idx].status = .live
            courts[idx].liveSince = Date()
            courts[idx].lastSnapshot = ScoreSnapshot(
                courtId: 2,
                matchId: 2001,
                status: "In Progress",
                setNumber: 1,
                team1Name: courtTwoMatch.team1Name ?? "Team 1",
                team2Name: courtTwoMatch.team2Name ?? "Team 2",
                team1Seed: courtTwoMatch.team1Seed,
                team2Seed: courtTwoMatch.team2Seed,
                scheduledTime: courtTwoMatch.scheduledTime,
                matchNumber: courtTwoMatch.matchNumber,
                courtNumber: courtTwoMatch.courtNumber,
                team1Score: 0,
                team2Score: 0,
                serve: "home",
                setHistory: [
                    SetScore(setNumber: 1, team1Score: 12, team2Score: 10, isComplete: false)
                ],
                timestamp: Date(),
                setsToWin: courtTwoMatch.setsToWin ?? 2
            )
        }

        let courtThreeQueue = [
            MatchItem(
                apiURL: URL(string: "https://example.com/matches/3001/vmix")!,
                label: "11",
                team1Name: "Drew Nash / Avery Owen",
                team2Name: "Blake Price / Kendall Reed",
                team1Seed: "8",
                team2Seed: "9",
                matchType: "Bracket Play",
                scheduledTime: "10:00AM",
                startDate: "Sun",
                matchNumber: "11",
                courtNumber: "11",
                setsToWin: 2,
                pointsPerSet: 21
            )
        ]
        replaceQueue(3, with: courtThreeQueue, startIndex: 0)
        if let idx = courtIndex(for: 3) {
            courts[idx].status = .waiting
        }
    }
}

// MARK: - SignalRDelegate

extension AppViewModel: SignalRDelegate {
    func signalRStatusDidChange(_ status: SignalRStatus) {
        signalRStatus = status
        guard status != .connected else { return }

        for court in courts where court.status.isPolling {
            lastSignalRMutationAt.removeValue(forKey: court.id)
            lastSignalRMutationEpochMs.removeValue(forKey: court.id)
            clearSignalRMutationFallbackState(for: court.id)
            lastSignalRReconcileAt[court.id] = .distantPast
        }
    }

    func signalRDidConnect() {
        signalRStatus = .connected
        for court in courts where court.status.isPolling {
            lastSignalRReconcileAt[court.id] = .distantPast
        }
        syncSignalRSubscriptions(forceResubscribe: true)
    }

    func signalRDidReceiveMutation(name: String, payload: Any) {
        // Log all mutations
        let payloadStr: String
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: data, encoding: .utf8) {
            payloadStr = String(str.prefix(500))
        } else {
            payloadStr = "\(payload)"
        }
        scannerViewModel.addSignalRLog("[SignalR] '\(name)': \(payloadStr)")
        
        Task { @MainActor [weak self] in
            await self?.handleSignalRMutation(name: name, payload: payload)
        }
    }

    private func handleSignalRMutation(name: String, payload: Any) async {
        switch name {
        case "UPDATE_GAME":
            await handleSignalRGameMutation(payload: payload)
        case "UPDATE_DIVISION":
            guard let payloadDict = payload as? [String: Any] else { return }
            processDivisionMutation(payloadDict)
        default:
            break
        }
    }

    private func handleSignalRGameMutation(payload: Any) async {
        guard let dict = payload as? [String: Any],
              let gameId = dict["id"] as? Int else { return }

        if let ambiguousCourtIds = ambiguousGameIdToCourtIds[gameId], !ambiguousCourtIds.isEmpty {
            runtimeLog.log(
                .warning,
                subsystem: "signalr",
                message: "received UPDATE_GAME for ambiguous gameId \(gameId) on courts \(ambiguousCourtIds.sorted())"
            )
            await reconcileSignalRAmbiguousGameId(gameId, candidateCourtIds: ambiguousCourtIds.sorted())
            return
        }

        if let restoredCourtId = restoreRecentlyAdvancedMatchIfNeeded(gameId: gameId, payload: dict) {
            processGameMutation(courtId: restoredCourtId, gameId: gameId, payload: dict)
            return
        }

        guard let courtId = gameIdToCourtMap[gameId] else {
            runtimeLog.log(
                .warning,
                subsystem: "signalr",
                message: "received UPDATE_GAME for unknown gameId \(gameId)"
            )
            await resolveUnknownSignalRGameId(gameId)
            if let resolvedCourtId = gameIdToCourtMap[gameId] {
                processGameMutation(courtId: resolvedCourtId, gameId: gameId, payload: dict)
            }
            return
        }

        processGameMutation(courtId: courtId, gameId: gameId, payload: dict)
    }

    private func reconcileSignalRAmbiguousGameId(_ gameId: Int, candidateCourtIds: [Int]) async {
        for courtId in candidateCourtIds {
            lastSignalRMutationAt.removeValue(forKey: courtId)
            lastSignalRMutationEpochMs.removeValue(forKey: courtId)
            lastSignalRReconcileAt[courtId] = .distantPast
            await pollOnce(courtId)
        }
        runtimeLog.log(
            .info,
            subsystem: "signalr",
            message: "forced reconcile polls after ambiguous gameId \(gameId) on courts \(candidateCourtIds)"
        )
    }

    private func restoreRecentlyAdvancedMatchIfNeeded(gameId: Int, payload: [String: Any], now: Date = Date()) -> Int? {
        let isFinal = payload["isFinal"] as? Bool ?? false
        guard !isFinal else { return nil }

        for (courtId, context) in recentlyAutoAdvancedMatches {
            let reopenWindow = max(appSettings.holdScoreDuration, 180)
            guard now.timeIntervalSince(context.advancedAt) <= reopenWindow,
                  context.match.gameIds?.contains(gameId) == true,
                  let idx = courtIndex(for: courtId) else {
                continue
            }

            if courts[idx].status == .live, observedActiveScoring[courtId] == true {
                continue
            }

            guard let restoredIndex = courts[idx].queue.firstIndex(where: {
                $0.id == context.match.id || matchesRepresentSameContest($0, context.match)
            }) else {
                continue
            }

            courts[idx].activeIndex = restoredIndex
            courts[idx].status = .waiting
            courts[idx].lastSnapshot = nil
            courts[idx].liveSince = nil
            courts[idx].finishedAt = nil
            courts[idx].errorMessage = nil
            observedActiveScoring[courtId] = false
            smartSwitchFallbackOriginIndex.removeValue(forKey: courtId)
            smartSwitchedMatchID.removeValue(forKey: courtId)
            pendingSmartSwitchCandidate.removeValue(forKey: courtId)
            recentlyAutoAdvancedMatches.removeValue(forKey: courtId)
            rebuildGameIdMap()
            queueArbitrationReasonByCourt[courtId] = .reopenRecovery
            lastQueueArbitrationNoteByCourt.removeValue(forKey: courtId)
            runtimeLog.log(
                .info,
                subsystem: "queue",
                message: "restored recently advanced match on court \(courtId) after reopened gameId \(gameId)"
            )
            return courtId
        }

        return nil
    }

    private func resolveUnknownSignalRGameId(_ gameId: Int) async {
        let now = Date()
        let lastRefresh = lastSignalRUnknownGameRefreshAt[gameId] ?? .distantPast
        guard now.timeIntervalSince(lastRefresh) > 5 else { return }
        lastSignalRUnknownGameRefreshAt[gameId] = now

        for court in courts where court.status.isPolling {
            await refreshHydrateIfNeeded(for: court.id, force: true)
        }
        rebuildGameIdMap()
        syncSignalRSubscriptions()
        runtimeLog.log(
            .info,
            subsystem: "signalr",
            message: "refreshed hydrates after unknown gameId \(gameId)"
        )
    }

    private func handleSignalRMutationEpochMs(from payload: [String: Any]) -> Int64? {
        if let value = payload["dtModified"] as? Int64 { return value }
        if let value = payload["dtModified"] as? Int { return Int64(value) }
        if let value = payload["dtModified"] as? Double { return Int64(value) }
        if let value = payload["dtModified"] as? String { return Int64(value) }
        return nil
    }

    private func processDivisionMutation(_ payload: [String: Any]) {
        guard let divisionId = extractSignalRDivisionId(from: payload) else {
            runtimeLog.log(.warning, subsystem: "signalr", message: "received UPDATE_DIVISION without divisionId")
            return
        }

        var updatedCourts: [Int] = []
        for court in courts where court.status.isPolling {
            let wasUpdated = applyHydrateLookup(
                courtId: court.id,
                divisionId: divisionId,
                hydrateJSON: payload
            )
            if wasUpdated {
                updatedCourts.append(court.id)
            }
        }

        if !updatedCourts.isEmpty {
            rebuildGameIdMap()
            scheduleSave()
            runtimeLog.log(
                .info,
                subsystem: "signalr",
                message: "received UPDATE_DIVISION for division \(divisionId), updated courts \(updatedCourts)"
            )
        }
    }

    private func extractSignalRDivisionId(from payload: [String: Any]) -> Int? {
        if let divisionId = payload["divisionId"] as? Int { return divisionId }
        if let divisionId = payload["id"] as? Int { return divisionId }
        if let division = payload["division"] as? [String: Any], let divisionId = division["id"] as? Int {
            return divisionId
        }
        return nil
    }

    // MARK: - SignalR Subscription Management

    private func subscribeToAllActiveTournaments() {
        syncSignalRSubscriptions()
    }

    // MARK: - Mutation Processing

    private func processGameMutation(courtId: Int, gameId: Int, payload: [String: Any]) {
        if let mutationEpochMs = handleSignalRMutationEpochMs(from: payload),
           let lastEpoch = lastSignalRMutationEpochMs[courtId],
           mutationEpochMs <= lastEpoch {
            return
        }
        if let mutationEpochMs = handleSignalRMutationEpochMs(from: payload) {
            lastSignalRMutationEpochMs[courtId] = mutationEpochMs
        }
        lastSignalRMutationAt[courtId] = Date()
        clearSignalRMutationFallbackState(for: courtId)

        guard let idx = courtIndex(for: courtId),
              let activeIdx = courts[idx].activeIndex,
              activeIdx < courts[idx].queue.count else { return }

        let matchItem = courts[idx].queue[activeIdx]
        let homeScore = payload["home"] as? Int ?? 0
        let awayScore = payload["away"] as? Int ?? 0
        let gameNumber = payload["number"] as? Int ?? 0  // 0-indexed
        let isFinal = payload["isFinal"] as? Bool ?? false
        let winner = payload["_winner"] as? String

        // Build updated snapshot from current state
        var snapshot = courts[idx].lastSnapshot ?? .empty(courtId: courtId)

        // Update the correct set in setHistory
        let setIndex = gameNumber  // 0-indexed
        while snapshot.setHistory.count <= setIndex {
            snapshot.setHistory.append(SetScore(
                setNumber: snapshot.setHistory.count + 1,
                team1Score: 0,
                team2Score: 0,
                isComplete: false
            ))
        }

        let previousHome = snapshot.setHistory[setIndex].team1Score
        let previousAway = snapshot.setHistory[setIndex].team2Score

        snapshot.setHistory[setIndex].team1Score = homeScore
        snapshot.setHistory[setIndex].team2Score = awayScore
        snapshot.setHistory[setIndex].isComplete = isFinal

        // Recalculate match-level set scores
        let inferredFormat = inferMatchFormat(from: matchItem)
        var setsWon1 = 0
        var setsWon2 = 0
        for set in snapshot.setHistory where set.isComplete {
            if set.team1Score > set.team2Score { setsWon1 += 1 }
            else if set.team2Score > set.team1Score { setsWon2 += 1 }
        }

        snapshot.team1Score = setsWon1
        snapshot.team2Score = setsWon2
        snapshot.setNumber = snapshot.setHistory.count + (snapshot.setHistory.last?.isComplete == true ? 1 : 0)
        snapshot.setsToWin = inferredFormat.setsToWin
        snapshot.timestamp = Date()

        // Determine status
        let matchWon: Bool
        if let setsToPlay = matchItem.setsToPlay {
            // Pool play: must complete all mandatory sets
            let completedSets = snapshot.setHistory.filter { $0.isComplete }.count
            matchWon = completedSets >= setsToPlay
        } else {
            matchWon = setsWon1 >= inferredFormat.setsToWin || setsWon2 >= inferredFormat.setsToWin
        }
        if matchWon || (winner != nil && isFinal && snapshot.setHistory.allSatisfy({ $0.isComplete || $0 == snapshot.setHistory.last })) {
            // Check if match is actually concluded (all required sets won)
            if matchWon {
                snapshot.status = "Final"
            } else {
                snapshot.status = "In Progress"
            }
        } else if homeScore > 0 || awayScore > 0 || snapshot.setHistory.count > 1 {
            snapshot.status = "In Progress"
        }

        // Infer serving team from point changes
        if homeScore > previousHome {
            lastServeTeam[courtId] = "home"
            snapshot.serve = "home"
        } else if awayScore > previousAway {
            lastServeTeam[courtId] = "away"
            snapshot.serve = "away"
        } else if let serve = lastServeTeam[courtId] {
            snapshot.serve = serve
        }

        // Apply the snapshot update using shared downstream logic.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let _ = await self.applySnapshotUpdate(
                courtId: courtId,
                snapshot: snapshot,
                matchItem: matchItem,
                allowStaleAdvance: false
            )
        }

        runtimeLog.log(
            .info,
            subsystem: "signalr",
            message: "court \(courtId) updated from SignalR: set \(gameNumber + 1) -> \(homeScore)-\(awayScore)\(isFinal ? " (final)" : "")"
        )
    }

    /// Shared downstream logic for applying a score snapshot update.
    /// Used by both pollOnce and SignalR mutation processing.
    private func logCourtStatusTransition(
        courtId: Int,
        from previousStatus: CourtStatus,
        to newStatus: CourtStatus,
        snapshot: ScoreSnapshot,
        matchItem: MatchItem,
        isStale: Bool = false,
        matchConcluded: Bool = false
    ) {
        guard previousStatus != newStatus else { return }

        let matchup = describeMatchup(for: matchItem, snapshot: snapshot)
        switch (previousStatus, newStatus) {
        case (_, .live):
            runtimeLog.log(
                .info,
                subsystem: "queue",
                message: "court \(courtId) transitioned to live: \(matchup)"
            )
        case (_, .finished):
            let reason: String
            if isStale && !matchConcluded {
                reason = " due to stale scoring"
            } else if matchConcluded {
                reason = ""
            } else {
                reason = " after score update"
            }
            runtimeLog.log(
                .info,
                subsystem: "queue",
                message: "court \(courtId) transitioned to finished\(reason): \(matchup)"
            )
        case (_, .waiting):
            runtimeLog.log(
                .info,
                subsystem: "queue",
                message: "court \(courtId) transitioned to waiting: \(matchup)"
            )
        case (_, .error):
            runtimeLog.log(
                .warning,
                subsystem: "queue",
                message: "court \(courtId) transitioned to error: \(matchup)"
            )
        default:
            break
        }
    }

    private func describeMatchup(for matchItem: MatchItem, snapshot: ScoreSnapshot? = nil) -> String {
        let team1 = snapshot?.team1Name.trimmingCharacters(in: .whitespacesAndNewlines)
        let team2 = snapshot?.team2Name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTeam1 = matchItem.team1Name ?? (team1?.isEmpty == false ? team1 : nil) ?? "TBD"
        let resolvedTeam2 = matchItem.team2Name ?? (team2?.isEmpty == false ? team2 : nil) ?? "TBD"
        return "\(resolvedTeam1) vs \(resolvedTeam2)"
    }

    private func applySnapshotUpdate(
        courtId: Int,
        snapshot: ScoreSnapshot,
        matchItem: MatchItem,
        allowStaleAdvance: Bool
    ) async -> Bool {
        guard let idx = courtIndex(for: courtId),
              let activeIdx = courts[idx].activeIndex,
              activeIdx < courts[idx].queue.count else {
            return false
        }
        guard courts[idx].queue[activeIdx].id == matchItem.id else {
            return false
        }

        // Inactivity tracking
        let currentP1 = snapshot.setHistory.last?.team1Score ?? 0
        let currentP2 = snapshot.setHistory.last?.team2Score ?? 0
        let currentS1 = snapshot.team1Score
        let currentS2 = snapshot.team2Score
        let prevData = lastScoreSnapshot[courtId]

        if prevData == nil ||
           prevData?.pts1 != currentP1 || prevData?.pts2 != currentP2 ||
           prevData?.s1 != currentS1 || prevData?.s2 != currentS2 {
            lastScoreSnapshot[courtId] = (pts1: currentP1, pts2: currentP2, s1: currentS1, s2: currentS2)
            lastScoreChangeTime[courtId] = Date()
        }

        let timeSinceLastScore = Date().timeIntervalSince(lastScoreChangeTime[courtId] ?? Date())
        let isStale = allowStaleAdvance && timeSinceLastScore >= appSettings.staleMatchTimeout

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

        if matchConcluded || isStale {
            if isStale && !matchConcluded {
                runtimeLog.log(.warning, subsystem: "queue", message: "court \(courtId) match is stale, auto-advancing")
            }

            courts[idx].status = .finished
            courts[idx].lastSnapshot = snapshot
            if courts[idx].finishedAt == nil {
                courts[idx].finishedAt = Date()
            }
            logCourtStatusTransition(
                courtId: courtId,
                from: previousStatus,
                to: .finished,
                snapshot: snapshot,
                matchItem: matchItem,
                isStale: isStale,
                matchConcluded: matchConcluded
            )

            let didAdvance = await advanceQueueIfNeededAfterConclusion(
                courtId: courtId,
                snapshot: snapshot,
                previousStatus: previousStatus,
                matchConcluded: matchConcluded,
                isStale: isStale
            )

            courts[idx].lastPollTime = Date()
            return didAdvance
        } else {
            courts[idx].status = newStatus
            courts[idx].lastSnapshot = snapshot
            courts[idx].finishedAt = nil
            logCourtStatusTransition(
                courtId: courtId,
                from: previousStatus,
                to: newStatus,
                snapshot: snapshot,
                matchItem: matchItem
            )
        }

        courts[idx].lastPollTime = Date()
        return false
    }

    private func advanceQueueIfNeededAfterConclusion(
        courtId: Int,
        snapshot: ScoreSnapshot,
        previousStatus: CourtStatus,
        matchConcluded: Bool,
        isStale: Bool
    ) async -> Bool {
        guard let idx = courtIndex(for: courtId),
              let activeIdx = courts[idx].activeIndex else {
            return false
        }

        let nextIndex = activeIdx + 1
        guard nextIndex < courts[idx].queue.count else {
            return false
        }

        let hasScoreData = snapshot.setHistory.contains { $0.team1Score > 0 || $0.team2Score > 0 }
        let isFinalStatus = snapshot.status.lowercased().contains("final")
        let shouldHoldPostMatch = Self.shouldHoldPostMatch(
            matchConcluded: matchConcluded,
            observedActiveScoring: observedActiveScoring[courtId] ?? false,
            hasScoreData: hasScoreData,
            isFinalStatus: isFinalStatus,
            previousStatus: previousStatus
        )
        let timeSinceFinish = Date().timeIntervalSince(courts[idx].finishedAt ?? Date())
        let holdExpired = timeSinceFinish >= appSettings.holdScoreDuration
        let nextStarted = shouldHoldPostMatch ? await nextMatchHasStarted(courts[idx].queue[nextIndex]) : false
        let shouldAdvance = Self.shouldAdvanceAfterConclusion(
            matchConcluded: matchConcluded,
            isStale: isStale,
            holdExpired: holdExpired,
            shouldHoldPostMatch: shouldHoldPostMatch,
            nextMatchHasStarted: nextStarted
        )

        guard shouldAdvance else {
            return false
        }

        let targetIndex = await firstNonFinalQueueIndex(courtId: courtId, startingAt: nextIndex)
        guard let writeIdx = courtIndex(for: courtId),
              targetIndex < courts[writeIdx].queue.count else {
            return false
        }

        let finishedMatch = courts[writeIdx].queue[activeIdx]
        let nextMatch = courts[writeIdx].queue[targetIndex]
        let previousCourtStatus = courts[writeIdx].status
        courts[writeIdx].activeIndex = targetIndex
        courts[writeIdx].lastSnapshot = nil
        courts[writeIdx].status = .waiting
        courts[writeIdx].liveSince = nil
        courts[writeIdx].finishedAt = nil
        recentlyAutoAdvancedMatches[courtId] = RecentlyAdvancedMatchContext(
            match: finishedMatch,
            advancedAt: Date()
        )
        queueArbitrationReasonByCourt[courtId] = .queueDefault
        lastQueueArbitrationNoteByCourt.removeValue(forKey: courtId)
        logCourtStatusTransition(
            courtId: courtId,
            from: previousCourtStatus,
            to: .waiting,
            snapshot: .empty(courtId: courtId),
            matchItem: nextMatch
        )
        observedActiveScoring[courtId] = false
        forcedBroadcastLiveLayoutByCourt.remove(courtId)
        lastScoreChangeTime[courtId] = nil
        lastScoreSnapshot[courtId] = nil
        lastServeTeam.removeValue(forKey: courtId)

        let skippedCompleted = max(0, targetIndex - nextIndex)
        if skippedCompleted > 0 {
            runtimeLog.log(
                .info,
                subsystem: "queue",
                message: "auto-advanced court \(courtId) to match \(targetIndex + 1), skipped \(skippedCompleted) completed match(es)"
            )
        } else {
            runtimeLog.log(.info, subsystem: "queue", message: "auto-advanced court \(courtId) to match \(targetIndex + 1)")
        }

        rebuildGameIdMap()
        await refreshQueueMetadata(for: courtId)
        lastQueueRefreshTimes[courtId] = Date()
        scheduleSave()
        return true
    }

    static func shouldHoldPostMatch(
        matchConcluded: Bool,
        observedActiveScoring: Bool,
        hasScoreData: Bool,
        isFinalStatus: Bool,
        previousStatus: CourtStatus
    ) -> Bool {
        matchConcluded
            && (observedActiveScoring || hasScoreData || isFinalStatus)
            && (previousStatus == .live || previousStatus == .finished || hasScoreData || isFinalStatus)
    }

    static func shouldUseBroadcastIntermissionLayout(
        broadcastTransitionsEnabled: Bool,
        liveLayout: String,
        courtStatus: CourtStatus,
        hasCurrentMatch: Bool,
        hasScoreEvidence: Bool,
        forceLiveLayout: Bool
    ) -> Bool {
        guard broadcastTransitionsEnabled else {
            return false
        }

        guard liveLayout != "center",
              courtStatus.isPolling,
              courtStatus != .finished,
              hasCurrentMatch,
              !hasScoreEvidence,
              !forceLiveLayout else {
            return false
        }

        return true
    }

    static func shouldAdvanceAfterConclusion(
        matchConcluded: Bool,
        isStale: Bool,
        holdExpired: Bool,
        shouldHoldPostMatch: Bool,
        nextMatchHasStarted: Bool
    ) -> Bool {
        guard matchConcluded || isStale else {
            return false
        }

        return isStale || !shouldHoldPostMatch || holdExpired || nextMatchHasStarted
    }

    private func courtHasLiveScoreEvidence(_ court: Court) -> Bool {
        guard let snapshot = court.lastSnapshot else { return false }
        if snapshot.team1Score > 0 || snapshot.team2Score > 0 {
            return true
        }
        return snapshot.setHistory.contains { $0.team1Score > 0 || $0.team2Score > 0 }
    }
}

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
