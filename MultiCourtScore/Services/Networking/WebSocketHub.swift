//
//  WebSocketHub.swift
//  MultiCourtScore v2
//
//  Local HTTP server for OBS overlay endpoints
//

import Foundation
import Vapor
import Logging

struct OverlayHealthCourtSnapshot: Codable {
    let id: Int
    let name: String
    let status: String
    let currentMatch: String?
    let overlayURL: String
    let queueCount: Int
    let activeIndex: Int?
    let lastPollSecondsAgo: Int?
    let errorMessage: String?
    let isPolling: Bool
    let isStale: Bool
}

struct OverlayHealthSnapshot: Codable {
    let generatedAt: String
    let status: String
    let uptime: Int
    let serverStatus: String
    let startupError: String?
    let signalRStatus: String
    let signalREnabled: Bool
    let port: Int
    let courtCount: Int
    let signalRMutationFallbackCount: Int
    let signalRMutationFallbackCourts: [Int]
    let watchdogRestartCount: Int
    let lastWatchdogRecoveryAt: String?
    let lastWatchdogRecoveryReason: String?
    let stalePollingCourtIds: [Int]
    let errorCourtIds: [Int]
    let courts: [OverlayHealthCourtSnapshot]
}

@MainActor
final class WebSocketHub {
    static let shared = WebSocketHub()
    
    // App state reference
    weak var appViewModel: AppViewModel?
    
    // Vapor app
    private var app: Application?
    public private(set) var isRunning = false
    private var isStarting = false
    private var startedAt: Date?
    private var runningPort: Int?
    public private(set) var startupError: String?
    private let runtimeLog = RuntimeLogStore.shared
    private var shutdownTask: Task<Void, Never>?

    private init() {}

    // MARK: - Lifecycle

    func start(with viewModel: AppViewModel, port: Int = NetworkConstants.webSocketPort) async {
        guard !isRunning && !isStarting else {
            if isRunning {
                runtimeLog.log(.warning, subsystem: "overlay-server", message: "start requested while server is already running")
            }
            return
        }

        // Block further start calls immediately
        isStarting = true
        startupError = nil
        appViewModel = viewModel

        if let shutdownTask {
            runtimeLog.log(.info, subsystem: "overlay-server", message: "waiting for pending shutdown before restart")
            await shutdownTask.value
            self.shutdownTask = nil
        }
        
        // Ensure old app is cleaned up
        if let oldApp = app {
            runtimeLog.log(.info, subsystem: "overlay-server", message: "cleaning up existing server instance before restart")
            do {
                try await oldApp.asyncShutdown()
            } catch {
                runtimeLog.log(.warning, subsystem: "overlay-server", message: "error shutting down previous instance: \(error.localizedDescription)")
            }
            app = nil
        }

        // Initialize with explicit arguments to ignore Xcode/OS flags that crash Vapor
        let env = Environment(name: "production", arguments: ["vapor"])
        do {
            let newApp = try await Application.make(env)
            self.app = newApp
            
            // Configure server
            newApp.http.server.configuration.hostname = "127.0.0.1"
            newApp.http.server.configuration.port = port
            newApp.logger.logLevel = Logger.Level.warning
            
            // Install routes
            installRoutes(newApp)

            runtimeLog.log(.info, subsystem: "overlay-server", message: "starting on port \(port)")
            try await newApp.startup()

            isRunning = true
            isStarting = false
            startedAt = Date()
            runningPort = port
            startupError = nil
            runtimeLog.log(.info, subsystem: "overlay-server", message: "running at http://localhost:\(port)/overlay/court/X")
        } catch {
            let startupMessage = Self.describeStartupError(error, port: port)
            runtimeLog.log(.error, subsystem: "overlay-server", message: "failed to start on port \(port): \(error.localizedDescription)")
            self.isRunning = false
            self.isStarting = false
            self.startedAt = nil
            self.runningPort = nil
            self.app = nil
            self.startupError = startupMessage
        }
    }
    
    func stop() {
        guard isRunning || isStarting else { return }
        let appToStop = app
        app = nil
        isRunning = false
        isStarting = false
        startedAt = nil
        runningPort = nil
        let shutdownTask = Task.detached {
            RuntimeLogStore.shared.log(.info, subsystem: "overlay-server", message: "stopping")
            do {
                try await appToStop?.asyncShutdown()
            } catch {
                RuntimeLogStore.shared.log(.warning, subsystem: "overlay-server", message: "error during shutdown: \(error.localizedDescription)")
            }
            RuntimeLogStore.shared.log(.info, subsystem: "overlay-server", message: "stopped")
        }
        self.shutdownTask = shutdownTask
    }

    func waitForShutdownIfNeeded() async {
        guard let shutdownTask else { return }
        await shutdownTask.value
        if self.shutdownTask == shutdownTask {
            self.shutdownTask = nil
        }
    }

    func currentHealthSnapshot(port fallbackPort: Int = NetworkConstants.webSocketPort) -> OverlayHealthSnapshot {
        let now = Date()
        let uptimeSeconds: Int
        if let started = startedAt {
            uptimeSeconds = Int(now.timeIntervalSince(started))
        } else {
            uptimeSeconds = 0
        }

        let resolvedPort = runningPort ?? appViewModel?.appSettings.serverPort ?? fallbackPort
        let resolvedSignalRState = appViewModel?.signalRStatus ?? .disabled
        let resolvedSignalRStatus = resolvedSignalRState.displayLabel
        let signalREnabled = appViewModel?.appSettings.signalREnabled ?? false
        let watchdogRecoverySnapshot = appViewModel?.currentWatchdogRecoverySnapshot()
        let signalRMutationFallbackSnapshot = appViewModel?.currentSignalRMutationFallbackSnapshot()

        var stalePollingCourtIds: [Int] = []
        var errorCourtIds: [Int] = []
        let courts = (appViewModel?.courts ?? []).map { court -> OverlayHealthCourtSnapshot in
            let lastPollSecondsAgo = court.lastPollTime.map { Int(now.timeIntervalSince($0)) }
            let isPolling = court.status.isPolling
            let isStale = isPolling && (lastPollSecondsAgo ?? 0) > 30
            if isStale {
                stalePollingCourtIds.append(court.id)
            }
            if court.status == .error || ((court.errorMessage?.isEmpty == false) && isPolling) {
                errorCourtIds.append(court.id)
            }

            let currentMatch: String?
            if let idx = court.activeIndex, idx < court.queue.count {
                currentMatch = court.queue[idx].label ?? "Match \(idx + 1)"
            } else {
                currentMatch = nil
            }

            return OverlayHealthCourtSnapshot(
                id: court.id,
                name: court.name,
                status: court.status.rawValue,
                currentMatch: currentMatch,
                overlayURL: "http://localhost:\(resolvedPort)/overlay/court/\(court.id)/",
                queueCount: court.queue.count,
                activeIndex: court.activeIndex,
                lastPollSecondsAgo: lastPollSecondsAgo,
                errorMessage: court.errorMessage,
                isPolling: isPolling,
                isStale: isStale
            )
        }

        let signalRHealthIssue = signalREnabled && resolvedSignalRState.degradesHealthWhenEnabled
        let isDegraded = !isRunning || startupError != nil || !stalePollingCourtIds.isEmpty || !errorCourtIds.isEmpty || signalRHealthIssue

        return OverlayHealthSnapshot(
            generatedAt: ISO8601DateFormatter().string(from: now),
            status: isDegraded ? "degraded" : "ok",
            uptime: uptimeSeconds,
            serverStatus: isRunning ? "running" : "stopped",
            startupError: startupError,
            signalRStatus: resolvedSignalRStatus,
            signalREnabled: signalREnabled,
            port: resolvedPort,
            courtCount: courts.count,
            signalRMutationFallbackCount: signalRMutationFallbackSnapshot?.count ?? 0,
            signalRMutationFallbackCourts: signalRMutationFallbackSnapshot?.courts ?? [],
            watchdogRestartCount: watchdogRecoverySnapshot?.count ?? 0,
            lastWatchdogRecoveryAt: watchdogRecoverySnapshot?.lastRecoveryAt.map { ISO8601DateFormatter().string(from: $0) },
            lastWatchdogRecoveryReason: watchdogRecoverySnapshot?.lastRecoveryReason,
            stalePollingCourtIds: stalePollingCourtIds,
            errorCourtIds: errorCourtIds,
            courts: courts
        )
    }

    // MARK: - Routes

    private func installRoutes(_ app: Application) {
        // Health check — JSON with per-court status
        app.get("health") { req async throws -> Response in
            return try await MainActor.run {
                let snapshot = WebSocketHub.shared.currentHealthSnapshot()
                return try Self.jsonEncodable(snapshot)
            }
        }

        // Diagnostic page — human-readable overlay debug info
        app.get("debug", "court", ":id") { req async throws -> Response in
            return try await MainActor.run {
                let hub = WebSocketHub.shared
                guard let idStr = req.parameters.get("id"),
                      let courtId = Int(idStr) else {
                    return Response(status: .badRequest, body: .init(string: "Invalid court ID"))
                }

                var lines: [String] = []
                lines.append("=== Overlay Debug: Court \(courtId) ===\n")

                guard let vm = hub.appViewModel else {
                    lines.append("ERROR: appViewModel is nil (weak reference lost)")
                    lines.append("The server is running but has no connection to the app state.")
                    lines.append("This means ALL overlay endpoints return empty data.")
                    let response = Response(status: .ok)
                    response.headers.contentType = .plainText
                    response.body = .init(string: lines.joined(separator: "\n"))
                    return response
                }

                guard let court = vm.court(for: courtId) else {
                    lines.append("ERROR: No court found with id=\(courtId)")
                    lines.append("Available court IDs: \(vm.courts.map { $0.id })")
                    lines.append("\nThe overlay URL must match an existing court ID.")
                    lines.append("Try: http://localhost:\(NetworkConstants.webSocketPort)/overlay/court/\(vm.courts.first?.id ?? 1)/")
                    let response = Response(status: .ok)
                    response.headers.contentType = .plainText
                    response.body = .init(string: lines.joined(separator: "\n"))
                    return response
                }

                lines.append("Court: \(court.name) (id=\(court.id))")
                lines.append("Status: \(court.status.rawValue)")
                lines.append("Queue size: \(court.queue.count)")
                lines.append("Active index: \(court.activeIndex.map(String.init) ?? "nil")")

                if let match = court.currentMatch {
                    lines.append("\n--- Current Match ---")
                    lines.append("Label: \(match.label ?? "nil")")
                    lines.append("Team 1: \(match.team1Name ?? "nil")")
                    lines.append("Team 2: \(match.team2Name ?? "nil")")
                    lines.append("API URL: \(match.apiURL)")
                    lines.append("Sets to win: \(match.setsToWin.map(String.init) ?? "nil (default 2)")")
                } else {
                    lines.append("\nNo current match (activeIndex is nil or out of bounds)")
                }

                if let snap = court.lastSnapshot {
                    lines.append("\n--- Last Snapshot ---")
                    lines.append("Team 1: \(snap.team1Name) | Team 2: \(snap.team2Name)")
                    lines.append("Sets won: \(snap.team1Score) - \(snap.team2Score)")
                    lines.append("Set number: \(snap.setNumber)")
                    lines.append("Status: \(snap.status)")
                    lines.append("Set history: \(snap.setHistory.map { "(\($0.team1Score)-\($0.team2Score)\($0.isComplete ? " done" : ""))" }.joined(separator: ", "))")
                    lines.append("Has started: \(snap.hasStarted)")
                    lines.append("Is final: \(snap.isFinal)")
                    lines.append("Timestamp: \(snap.timestamp)")
                } else {
                    lines.append("\nlastSnapshot: nil (no API data received yet)")
                }

                if let lp = court.lastPollTime {
                    let ago = Date().timeIntervalSince(lp)
                    lines.append("\nLast poll: \(Int(ago))s ago")
                } else {
                    lines.append("\nLast poll: never")
                }

                if let err = court.errorMessage {
                    lines.append("Error: \(err)")
                }

                lines.append("\n--- What the overlay JS sees ---")
                let isLiveOrFinished = court.status == .live || court.status == .finished
                let currentGame = court.lastSnapshot?.setHistory.last
                let score1 = isLiveOrFinished ? (currentGame?.team1Score ?? court.currentMatch?.team1_score ?? 0) : 0
                let score2 = isLiveOrFinished ? (currentGame?.team2Score ?? court.currentMatch?.team2_score ?? 0) : 0
                lines.append("score1 (current set points): \(score1)")
                lines.append("score2 (current set points): \(score2)")
                lines.append("courtStatus: \(court.status.rawValue)")
                lines.append("isLiveOrFinished: \(isLiveOrFinished)")

                let combinedScore = score1 + score2
                let setsWon1 = isLiveOrFinished ? (court.lastSnapshot?.totalSetsWon.team1 ?? 0) : 0
                let setsWon2 = isLiveOrFinished ? (court.lastSnapshot?.totalSetsWon.team2 ?? 0) : 0
                let matchInProgress = setsWon1 > 0 || setsWon2 > 0

                if (court.status == .waiting || court.status == .idle) && combinedScore == 0 && !matchInProgress {
                    lines.append("JS state: INTERMISSION (team names + 'Match Starting Soon')")
                } else if combinedScore > 0 {
                    lines.append("JS state: SCORING (live scoreboard visible)")
                } else if setsWon1 >= (court.currentMatch?.setsToWin ?? 2) || setsWon2 >= (court.currentMatch?.setsToWin ?? 2) {
                    lines.append("JS state: POSTMATCH (final score + celebration)")
                } else {
                    lines.append("JS state: current overlay state preserved")
                }

                lines.append("\n--- URLs ---")
                lines.append("Overlay: http://localhost:\(NetworkConstants.webSocketPort)/overlay/court/\(courtId)/")
                lines.append("Score JSON: http://localhost:\(NetworkConstants.webSocketPort)/overlay/court/\(courtId)/score.json")
                lines.append("This debug: http://localhost:\(NetworkConstants.webSocketPort)/debug/court/\(courtId)")

                let response = Response(status: .ok)
                response.headers.contentType = .plainText
                response.body = .init(string: lines.joined(separator: "\n"))
                return response
            }
        }

        app.get("debug", "logs") { _ async throws -> Response in
            let response = Response(status: .ok)
            response.headers.contentType = .plainText

            let logText = self.runtimeLog.recentEntries()
            if logText.isEmpty {
                response.body = .init(string: "Runtime log is empty.\nPath: \(self.runtimeLog.logFilePath)")
            } else {
                response.body = .init(string: "Path: \(self.runtimeLog.logFilePath)\n\n\(logText)")
            }
            return response
        }

        // Main overlay page
        app.get("overlay", "court", ":id") { req async throws -> Response in
            return try await MainActor.run {
                let hub = WebSocketHub.shared
                guard let idStr = req.parameters.get("id") else {
                    return Response(status: .notFound)
                }
                let html = hub.generateOverlayHTML(courtId: idStr)
                let response = Response(status: .ok)
                response.headers.contentType = .html
                response.headers.cacheControl = .init(noStore: true)
                response.body = .init(string: html)
                return response
            }
        }

        // Also serve overlay with trailing slash (no redirect to avoid loops)
        app.get("overlay", "court", ":id", "") { req async throws -> Response in
            return try await MainActor.run {
                let hub = WebSocketHub.shared
                let idStr = req.parameters.get("id") ?? "1"
                let html = hub.generateOverlayHTML(courtId: idStr)
                let response = Response(status: .ok)
                response.headers.contentType = .html
                response.headers.cacheControl = .init(noStore: true)
                response.body = .init(string: html)
                return response
            }
        }

        // Score JSON endpoint
        app.get("overlay", "court", ":id", "score.json") { req async throws -> Response in
            // Execute on MainActor to safely access AppViewModel
            return try await MainActor.run {
                let hub = WebSocketHub.shared
                let defaultShowSocialBar = hub.appViewModel?.appSettings.showSocialBar ?? true
                let defaultShowNextMatchBar = hub.appViewModel?.appSettings.showNextMatchBar ?? true
                let defaultBroadcastTransitionsEnabled = hub.appViewModel?.appSettings.broadcastTransitionsEnabled ?? false
                guard let vm = hub.appViewModel,
                      let idStr = req.parameters.get("id"),
                      let courtId = Int(idStr),
                      let court = vm.court(for: courtId)
                else {
                    // Return empty structure if court not found
                    return try Self.json([
                        "team1": "", "team2": "", "score1": 0, "score2": 0,
                        "set": 1, "status": "Waiting",
                        "setsA": 0, "setsB": 0,
                        "seed1": "", "seed2": "",
                        "setHistory": [] as [String],
                        "nextMatch": "",
                        "overlayState": "intermission",
                        "layout": "bottom-left",
                        "showSocialBar": defaultShowSocialBar,
                        "showNextMatchBar": defaultShowNextMatchBar,
                        "broadcastTransitionsEnabled": defaultBroadcastTransitionsEnabled
                    ])
                }
                
                let resolvedActiveIndex: Int? = {
                    guard !court.queue.isEmpty else { return nil }
                    guard let activeIndex = court.activeIndex else { return 0 }
                    return min(max(0, activeIndex), court.queue.count - 1)
                }()
                let currentMatch = resolvedActiveIndex.map { court.queue[$0] } ?? court.queue.first
                let nextMatch: MatchItem? = {
                    guard let activeIndex = resolvedActiveIndex else { return nil }
                    let nextIndex = activeIndex + 1
                    guard nextIndex < court.queue.count else { return nil }
                    return court.queue[nextIndex]
                }()

                // Get team names - prefer snapshot, fallback to MatchItem (from scanner)
                let snapshot = court.lastSnapshot
                let team1 = snapshot?.team1Name.isEmpty == false ? snapshot!.team1Name : (currentMatch?.team1Name ?? "")
                let team2 = snapshot?.team2Name.isEmpty == false ? snapshot!.team2Name : (currentMatch?.team2Name ?? "")
                let seed1 = snapshot?.team1Seed ?? currentMatch?.team1Seed ?? ""
                let seed2 = snapshot?.team2Seed ?? currentMatch?.team2Seed ?? ""

                // Force scores to 0-0 when court is not actively live or finished
                // This prevents stale scores from a previous match lingering during auto-advance
                let overlayState = vm.effectiveOverlayState(for: court)
                let isOverlayScoring = overlayState == "scoring"

                let currentGame = snapshot?.setHistory.last
                let rawGameScore1 = isOverlayScoring ? (currentGame?.team1Score ?? currentMatch?.team1_score ?? 0) : 0
                let rawGameScore2 = isOverlayScoring ? (currentGame?.team2Score ?? currentMatch?.team2_score ?? 0) : 0
                let gameScore1 = rawGameScore1 >= 60 ? abs(rawGameScore1) % 10 : rawGameScore1
                let gameScore2 = rawGameScore2 >= 60 ? abs(rawGameScore2) % 10 : rawGameScore2
                let scoreSafetySanitized = isOverlayScoring && (rawGameScore1 != gameScore1 || rawGameScore2 != gameScore2)

                // Determine effective layout
                let effectiveLayout = vm.effectiveOverlayLayout(for: court)
                let socialBarEnabled = court.socialBarEnabled ?? vm.appSettings.showSocialBar
                let nextMatchBarEnabled = court.nextMatchBarEnabled ?? vm.appSettings.showNextMatchBar
                let broadcastTransitionsEnabled = vm.effectiveBroadcastTransitionsEnabled(for: court)
                let overlayStatus: String = {
                    guard isOverlayScoring else { return "Pre-Match" }
                    if scoreSafetySanitized {
                        return (gameScore1 > 0 || gameScore2 > 0) ? "In Progress" : "Pre-Match"
                    }
                    if let snapshotStatus = snapshot?.status, !snapshotStatus.isEmpty {
                        return snapshotStatus
                    }
                    switch court.status {
                    case .finished:
                        return "Final"
                    case .live:
                        return "In Progress"
                    default:
                        return "Pre-Match"
                    }
                }()

                let data: [String: Any] = [
                    "team1": team1,
                    "team2": team2,
                    "score1": gameScore1,
                    "score2": gameScore2,
                    "scoreSafetySanitized": scoreSafetySanitized,
                    "set": isOverlayScoring ? (snapshot?.setNumber ?? 1) : 1,
                    "status": overlayStatus,
                    "courtStatus": court.status.rawValue,
                    "overlayState": overlayState,
                    "setsA": isOverlayScoring ? (snapshot?.totalSetsWon.team1 ?? 0) : 0,
                    "setsB": isOverlayScoring ? (snapshot?.totalSetsWon.team2 ?? 0) : 0,
                    "serve": isOverlayScoring ? (snapshot?.serve ?? "none") : "none",
                    "setHistory": isOverlayScoring ? (snapshot?.setHistory.map { $0.displayString } ?? []) : [] as [String],

                    "seed1": seed1,
                    "seed2": seed2,

                    "setsToWin": currentMatch?.setsToWin ?? 2,
                    "pointsPerSet": currentMatch?.pointsPerSet ?? 21,
                    "pointCap": currentMatch?.pointCap as Any,

                    "matchNumber": currentMatch?.matchNumber ?? "",
                    "matchType": currentMatch?.matchType ?? "",
                    "typeDetail": currentMatch?.typeDetail ?? "",
                    "nextMatch": Self.localizeNextMatch(
                        nextMatch?.displayName ?? "",
                        queue: court.queue,
                        activeIndex: resolvedActiveIndex
                    ),
                    "layout": effectiveLayout,
                    "showSocialBar": socialBarEnabled,
                    "showNextMatchBar": nextMatchBarEnabled,
                    "broadcastTransitionsEnabled": broadcastTransitionsEnabled,
                    "holdDuration": vm.appSettings.holdScoreDuration * 1000
                ]
                
                return try Self.json(data)
            }
        }
        
        // Label endpoint
        app.get("overlay", "court", ":id", "label.json") { req async throws -> Response in
            return try await MainActor.run {
                let hub = WebSocketHub.shared
                guard let vm = hub.appViewModel,
                      let idStr = req.parameters.get("id"),
                      let courtId = Int(idStr),
                      let courtIdx = vm.courtIndex(for: courtId)
                else {
                    return try Self.json(["label": NSNull()])
                }
                
                var label = ""
                if let activeIdx = vm.courts[courtIdx].activeIndex,
                   activeIdx >= 0,
                   activeIdx < vm.courts[courtIdx].queue.count {
                    label = vm.courts[courtIdx].queue[activeIdx].label ?? ""
                }
                
                return try Self.json(["label": label.isEmpty ? NSNull() : label])
            }
        }
        
        // Next match endpoint
        app.get("overlay", "court", ":id", "next.json") { req async throws -> Response in
            guard let idStr = req.parameters.get("id"),
                  let courtId = Int(idStr) else {
                return try Self.json(["a": NSNull(), "b": NSNull(), "label": NSNull()])
            }
            
            // Fetch match data on MainActor to satisfy concurrency requirements
            let matchData = await MainActor.run { () -> (url: URL, t1: String?, t2: String?, label: String?)? in
                let hub = WebSocketHub.shared
                guard let vm = hub.appViewModel,
                      let courtIdx = vm.courtIndex(for: courtId),
                      let activeIdx = vm.courts[courtIdx].activeIndex
                else { return nil }
                
                let nextIdx = activeIdx + 1
                guard nextIdx < vm.courts[courtIdx].queue.count else { return nil }
                
                let m = vm.courts[courtIdx].queue[nextIdx]
                return (m.apiURL, m.team1Name, m.team2Name, m.label)
            }
            
            // If no match data, return empty
            guard let data = matchData else {
                return try Self.json(["a": NSNull(), "b": NSNull(), "label": NSNull()])
            }
            
            // Fetch names from API (off MainActor) with timeout
            do {
                var request = URLRequest(url: data.url)
                request.timeoutInterval = 5.0
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (responseData, _) = try await URLSession.shared.data(for: request)
                let (a, b) = Self.extractNames(from: responseData)
                
                return try Self.json([
                    "a": a ?? NSNull(),
                    "b": b ?? NSNull(),
                    "label": data.label ?? NSNull()
                ])
            } catch {
                return try Self.json([
                    "a": data.t1 ?? NSNull(),
                    "b": data.t2 ?? NSNull(),
                    "label": data.label ?? NSNull()
                ])
            }
        }

    }
    
    // MARK: - Helpers
    
    private func cacheBusted(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url // Return original URL if parsing fails
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "_t", value: String(Int(Date().timeIntervalSince1970 * 1000))))
        components.queryItems = items
        return components.url ?? url
    }
    
    private nonisolated static func json(_ dict: [String: Any]) throws -> Response {
        let data = try JSONSerialization.data(withJSONObject: dict)
        let response = Response(status: .ok)
        response.headers.contentType = .json
        response.headers.cacheControl = .init(noStore: true)
        response.body = .init(data: data)
        return response
    }

    private nonisolated static func jsonEncodable<T: Encodable>(_ value: T) throws -> Response {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        let response = Response(status: .ok)
        response.headers.contentType = .json
        response.headers.cacheControl = .init(noStore: true)
        response.body = .init(data: data)
        return response
    }

    private static func describeStartupError(_ error: Error, port: Int) -> String {
        "Port \(port) unavailable: \(error.localizedDescription). Another app or MultiCourtScore instance may already be using it."
    }

    /// Replace "Match N" with "this match" in the next-match display string
    /// when Match N is the currently active match on this court.
    private nonisolated static func localizeNextMatch(
        _ text: String,
        queue: [MatchItem],
        activeIndex: Int?
    ) -> String {
        guard !text.isEmpty, let activeIdx = activeIndex else { return text }

        guard let regex = try? NSRegularExpression(
            pattern: #"Match\s+(\d+)"#,
            options: .caseInsensitive
        ) else { return text }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        // Build a map: bracket match number → queue index
        // Method 1: use explicit matchNumber fields
        var numberToIndex: [String: Int] = [:]
        for (idx, item) in queue.enumerated() {
            if let mn = item.matchNumber, !mn.isEmpty {
                numberToIndex[mn] = idx
            }
        }

        // Method 2: if no match numbers are set, assume sequential bracket numbering
        // (Match 1 = queue[0], Match 2 = queue[1], etc.)
        let hasAnyMatchNumbers = queue.contains { $0.matchNumber?.isEmpty == false }
        if !hasAnyMatchNumbers {
            for idx in queue.indices {
                numberToIndex[String(idx + 1)] = idx
            }
        }

        // Apply substitutions (iterate in reverse to preserve ranges)
        var result = text
        for match in matches.reversed() {
            guard let numRange = Range(match.range(at: 1), in: result) else { continue }
            let numStr = String(result[numRange])
            if let queueIdx = numberToIndex[numStr], queueIdx == activeIdx {
                guard let fullRange = Range(match.range, in: result) else { continue }
                result.replaceSubrange(fullRange, with: "this match")
            }
        }

        return result
    }
    
    private nonisolated static func extractNames(from data: Data) -> (String?, String?) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            return (nil, nil)
        }
        
        // vMix array format
        if let arr = obj as? [[String: Any]], arr.count >= 2 {
            let a = arr[0]["teamName"] as? String
            let b = arr[1]["teamName"] as? String
            return (a, b)
        }
        
        // Dictionary format
        if let dict = obj as? [String: Any] {
            // Favor bracket text (e.g. "Winner of Match 5") over generic "Team A" 
            let a = dict["team1_text"] as? String ?? dict["homeTeam"] as? String ?? dict["team1Name"] as? String
            let b = dict["team2_text"] as? String ?? dict["awayTeam"] as? String ?? dict["team2Name"] as? String
            return (a, b)
        }
        
        return (nil, nil)
    }
    
    // MARK: - Overlay HTML

    // Cache generated HTML per court ID to avoid 3x 50KB string copies per request
    private var overlayHTMLCache: [String: String] = [:]

    private func generateOverlayHTML(courtId: String) -> String {
        if let cached = overlayHTMLCache[courtId] { return cached }
        let html = Self.bvmOverlayHTML
            .replacingOccurrences(
                of: #"const SRC = "/score.json";"#,
                with: #"const SRC = "/overlay/court/\#(courtId)/score.json";"#
            )
            .replacingOccurrences(
                of: #"const NEXT_SRC = "/next.json";"#,
                with: #"const NEXT_SRC = "/overlay/court/\#(courtId)/next.json";"#
            )
        overlayHTMLCache[courtId] = html
        return html
    }
    
    // MARK: - Overlay HTML
    private static let bvmOverlayHTML: String = loadOverlayHTML()

    private static func loadOverlayHTML() -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/overlay.html")
        if let html = try? String(contentsOf: sourceURL, encoding: .utf8) {
            return html
        }

        let bundleCandidates = Bundle.allBundles + Bundle.allFrameworks + [Bundle.main]
        if let bundleURL = bundleCandidates
            .first(where: {
                $0.bundleIdentifier == "com.NathanHicks.MultiCourtScore"
                    || $0.bundleURL.lastPathComponent == "MultiCourtScore.app"
            })?
            .url(forResource: "overlay", withExtension: "html"),
           let html = try? String(contentsOf: bundleURL, encoding: .utf8) {
            return html
        }

        assertionFailure("Unable to load overlay.html from bundle or source path.")
        return "<!DOCTYPE html><html><body>Overlay unavailable</body></html>"
    }

    static var embeddedOverlayHTMLForTesting: String {
        bvmOverlayHTML
    }
}
