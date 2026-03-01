//
//  WebSocketHub.swift
//  MultiCourtScore v2
//
//  Local HTTP server for OBS overlay endpoints
//

import Foundation
import Vapor
import Logging

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

    private init() {}

    // MARK: - Lifecycle

    func start(with viewModel: AppViewModel, port: Int = NetworkConstants.webSocketPort) async {
        guard !isRunning && !isStarting else {
            if isRunning { print("⚠️ Overlay server already running") }
            return
        }

        // Block further start calls immediately
        isStarting = true
        appViewModel = viewModel
        
        // Ensure old app is cleaned up
        if let oldApp = app {
            print("Cleaning up existing server instance...")
            do {
                try await oldApp.asyncShutdown()
            } catch {
                print("Error shutting down old app: \(error)")
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
            
            // Start server in background
            Task.detached(priority: .utility) { [newApp] in
                do {
                    print("⏳ Starting overlay server on port \(port)...")
                    try await newApp.startup()

                    await MainActor.run {
                        WebSocketHub.shared.isRunning = true
                        WebSocketHub.shared.isStarting = false
                        WebSocketHub.shared.startedAt = Date()
                        print("✅ Overlay server running at http://localhost:\(port)/overlay/court/X")
                    }
                } catch {
                    print("❌ Failed to start overlay server: \(error)")
                    await MainActor.run {
                        WebSocketHub.shared.isRunning = false
                        WebSocketHub.shared.isStarting = false
                        WebSocketHub.shared.app = nil
                    }
                }
            }
        } catch {
            print("❌ Failed to initialize Vapor Application: \(error)")
            self.isRunning = false
            self.isStarting = false
        }
    }
    
    func stop() {
        guard isRunning || isStarting else { return }
        let appToStop = app
        app = nil
        isRunning = false
        isStarting = false
        startedAt = nil
        Task.detached {
            print("🛑 Stopping overlay server...")
            do {
                try await appToStop?.asyncShutdown()
            } catch {
                print("⚠️ Error shutting down app: \(error)")
            }
            print("🛑 Overlay server stopped")
        }
    }

    // MARK: - Routes

    private func installRoutes(_ app: Application) {
        // Health check — JSON with per-court status
        app.get("health") { req async throws -> Response in
            return try await MainActor.run {
                let hub = WebSocketHub.shared
                let now = Date()

                let uptimeSeconds: Int
                if let started = hub.startedAt {
                    uptimeSeconds = Int(now.timeIntervalSince(started))
                } else {
                    uptimeSeconds = 0
                }

                var courtEntries: [[String: Any]] = []
                var isDegraded = false

                if let vm = hub.appViewModel {
                    for court in vm.courts {
                        let lastPollAgo: Double?
                        if let lp = court.lastPollTime {
                            lastPollAgo = now.timeIntervalSince(lp)
                        } else {
                            lastPollAgo = nil
                        }

                        // Flag degraded if a polling court hasn't been polled in 30s
                        if court.status.isPolling, let ago = lastPollAgo, ago > 30 {
                            isDegraded = true
                        }

                        let currentMatch: String
                        if let idx = court.activeIndex, idx < court.queue.count {
                            currentMatch = court.queue[idx].label ?? "Match \(idx + 1)"
                        } else {
                            currentMatch = ""
                        }

                        var entry: [String: Any] = [
                            "id": court.id,
                            "name": court.name,
                            "status": court.status.rawValue,
                            "currentMatch": currentMatch,
                            "overlayURL": "http://localhost:\(NetworkConstants.webSocketPort)/overlay/court/\(court.id)/"
                        ]

                        if let ago = lastPollAgo {
                            entry["lastPollSecondsAgo"] = Int(ago)
                        }

                        if let err = court.errorMessage, !err.isEmpty {
                            entry["errorMessage"] = err
                        }

                        courtEntries.append(entry)
                    }
                }

                let result: [String: Any] = [
                    "status": isDegraded ? "degraded" : "ok",
                    "uptime": uptimeSeconds,
                    "courts": courtEntries
                ]

                return try Self.json(result)
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
                response.body = .init(string: html)
                return response
            }
        }

        // Score JSON endpoint
        app.get("overlay", "court", ":id", "score.json") { req async throws -> Response in
            // Execute on MainActor to safely access AppViewModel
            return try await MainActor.run {
                let hub = WebSocketHub.shared
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
                        "nextMatch": ""
                    ])
                }
                
                // Get team names - prefer snapshot, fallback to MatchItem (from scanner)
                let snapshot = court.lastSnapshot
                let currentMatch = court.currentMatch
                let team1 = snapshot?.team1Name.isEmpty == false ? snapshot!.team1Name : (currentMatch?.team1Name ?? "")
                let team2 = snapshot?.team2Name.isEmpty == false ? snapshot!.team2Name : (currentMatch?.team2Name ?? "")
                let seed1 = snapshot?.team1Seed ?? currentMatch?.team1Seed ?? ""
                let seed2 = snapshot?.team2Seed ?? currentMatch?.team2Seed ?? ""

                // Force scores to 0-0 when court is not actively live or finished
                // This prevents stale scores from a previous match lingering during auto-advance
                let isLiveOrFinished = court.status == .live || court.status == .finished

                let currentGame = snapshot?.setHistory.last
                let gameScore1 = isLiveOrFinished ? (currentGame?.team1Score ?? currentMatch?.team1_score ?? 0) : 0
                let gameScore2 = isLiveOrFinished ? (currentGame?.team2Score ?? currentMatch?.team2_score ?? 0) : 0

                // Determine effective layout
                let effectiveLayout = court.scoreboardLayout ?? vm.appSettings.defaultScoreboardLayout

                let data: [String: Any] = [
                    "team1": team1,
                    "team2": team2,
                    "score1": gameScore1,
                    "score2": gameScore2,
                    "set": isLiveOrFinished ? (snapshot?.setNumber ?? 1) : 1,
                    "status": isLiveOrFinished ? (snapshot?.status ?? "Pre-Match") : "Pre-Match",
                    "courtStatus": court.status.rawValue,
                    "setsA": isLiveOrFinished ? (snapshot?.totalSetsWon.team1 ?? 0) : 0,
                    "setsB": isLiveOrFinished ? (snapshot?.totalSetsWon.team2 ?? 0) : 0,
                    "serve": isLiveOrFinished ? (snapshot?.serve ?? "none") : "none",
                    "setHistory": isLiveOrFinished ? (snapshot?.setHistory.map { $0.displayString } ?? []) : [] as [String],

                    "seed1": seed1,
                    "seed2": seed2,

                    "setsToWin": currentMatch?.setsToWin ?? 2,
                    "pointsPerSet": currentMatch?.pointsPerSet ?? 21,
                    "pointCap": currentMatch?.pointCap as Any,

                    "matchNumber": currentMatch?.matchNumber ?? "",
                    "matchType": currentMatch?.matchType ?? "",
                    "typeDetail": currentMatch?.typeDetail ?? "",
                    "nextMatch": Self.localizeNextMatch(
                        court.nextMatch?.displayName ?? "",
                        queue: court.queue,
                        activeIndex: court.activeIndex
                    ),
                    "layout": effectiveLayout,
                    "showSocialBar": vm.appSettings.showSocialBar,
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
    
    // MARK: - Embedded HTML (Stitch-generated Tailwind overlay)
    private static let bvmOverlayHTML: String = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta content="width=device-width, initial-scale=1.0" name="viewport"/>
<title>BVM Scoreboard Overlay</title>
<link href="https://fonts.googleapis.com/css2?family=Roboto+Condensed:ital,wght@0,100..900;1,100..900&display=swap" rel="stylesheet"/>
<style>
/* Tailwind utility classes compiled inline for overlay */
.carbon-bar {
  background: linear-gradient(180deg, #1A1A1A 0%, #080808 100%);
  border: 1px solid rgba(255, 255, 255, 0.12);
}
.text-gold-gradient {
  background: linear-gradient(180deg, #F9E29B 0%, #D4AF37 100%);
  -webkit-background-clip: text;
  background-clip: text;
  -webkit-text-fill-color: transparent;
}
.set-pip {
  width: 1.5rem;
  height: 0.375rem;
  border-radius: 9999px;
}
.score-container {
  display: flex;
  align-items: center;
  justify-content: center;
  min-width: 4rem;
  padding: 0.5rem 1rem;
}
.score-text {
  font-size: 2.25rem;
  font-weight: 900;
  background: linear-gradient(180deg, #F9E29B 0%, #D4AF37 100%);
  -webkit-background-clip: text;
  background-clip: text;
  -webkit-text-fill-color: transparent;
  font-variant-numeric: tabular-nums;
  font-style: italic;
  line-height: 1.15;
  padding-bottom: 2px;
  padding: 0.25em 0.35em;
  transition: transform 0.15s ease-out, opacity 0.15s ease-out;
}
/* Score flip animation */
.score-flip {
  animation: score-flip-anim 0.3s ease-out;
}
@keyframes score-flip-anim {
  0% { transform: rotateX(-90deg) scale(0.8); opacity: 0; }
  50% { transform: rotateX(15deg) scale(1.1); opacity: 0.8; }
  100% { transform: rotateX(0deg) scale(1); opacity: 1; }
}
/* Status bubble with subtle pulse animation */
.status-bubble {
  animation: status-pulse 2.5s ease-in-out infinite;
}
@keyframes status-pulse {
  0%, 100% { 
    box-shadow: 0 4px 12px rgba(0,0,0,0.5), 0 0 8px rgba(212,175,55,0.2);
    transform: scale(1);
  }
  50% { 
    box-shadow: 0 4px 16px rgba(0,0,0,0.6), 0 0 15px rgba(212,175,55,0.4);
    transform: scale(1.02);
  }
}
.bubble-bar {
  background: rgba(0, 0, 0, 0.8);
  backdrop-filter: blur(8px);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-top: none;
  border-radius: 0 0 0.5rem 0.5rem;
  overflow: hidden;
}
.bg-gold { background-color: #D4AF37; }
.bg-gold-muted { background-color: rgba(212, 175, 55, 0.25); }

/* Confetti celebration - 3D tumbling flat rectangles */
@keyframes cf-drift-1 {
  0% { transform: translateY(-15px) translateX(0px) rotateY(0deg) rotateZ(0deg); opacity: 0; }
  3% { opacity: 0.9; }
  20% { transform: translateY(25px) translateX(8px) rotateY(90deg) rotateZ(20deg); opacity: 0.95; }
  40% { transform: translateY(55px) translateX(-5px) rotateY(180deg) rotateZ(45deg); }
  60% { transform: translateY(85px) translateX(10px) rotateY(270deg) rotateZ(70deg); }
  80% { transform: translateY(115px) translateX(-3px) rotateY(360deg) rotateZ(95deg); opacity: 0.9; }
  90% { opacity: 0.85; }
  100% { transform: translateY(140px) translateX(6px) rotateY(450deg) rotateZ(120deg); opacity: 0; }
}
@keyframes cf-drift-2 {
  0% { transform: translateY(-15px) translateX(0px) rotateY(0deg) rotateZ(0deg); opacity: 0; }
  3% { opacity: 0.85; }
  22% { transform: translateY(28px) translateX(-10px) rotateY(-80deg) rotateZ(-15deg); opacity: 0.9; }
  44% { transform: translateY(62px) translateX(6px) rotateY(-160deg) rotateZ(-35deg); }
  66% { transform: translateY(98px) translateX(-8px) rotateY(-240deg) rotateZ(-55deg); }
  88% { transform: translateY(128px) translateX(4px) rotateY(-320deg) rotateZ(-75deg); opacity: 0.9; }
  90% { opacity: 0.85; }
  100% { transform: translateY(145px) translateX(-3px) rotateY(-400deg) rotateZ(-95deg); opacity: 0; }
}
@keyframes cf-drift-3 {
  0% { transform: translateY(-15px) translateX(0px) rotateY(0deg) rotateZ(0deg); opacity: 0; }
  3% { opacity: 0.8; }
  25% { transform: translateY(30px) translateX(12px) rotateY(70deg) rotateZ(25deg); opacity: 0.85; }
  50% { transform: translateY(70px) translateX(-8px) rotateY(140deg) rotateZ(55deg); }
  75% { transform: translateY(110px) translateX(6px) rotateY(210deg) rotateZ(85deg); opacity: 0.9; }
  90% { opacity: 0.8; }
  100% { transform: translateY(142px) translateX(-4px) rotateY(280deg) rotateZ(115deg); opacity: 0; }
}
@keyframes cf-drift-4 {
  0% { transform: translateY(-15px) translateX(0px) rotateY(0deg) rotateZ(0deg); opacity: 0; }
  3% { opacity: 0.95; }
  18% { transform: translateY(22px) translateX(-12px) rotateY(-100deg) rotateZ(-20deg); opacity: 0.9; }
  36% { transform: translateY(50px) translateX(10px) rotateY(-200deg) rotateZ(-40deg); }
  54% { transform: translateY(78px) translateX(-6px) rotateY(-300deg) rotateZ(-60deg); }
  72% { transform: translateY(106px) translateX(8px) rotateY(-400deg) rotateZ(-80deg); opacity: 0.9; }
  90% { transform: translateY(130px) translateX(-4px) rotateY(-500deg) rotateZ(-100deg); opacity: 0.8; }
  100% { transform: translateY(148px) translateX(5px) rotateY(-540deg) rotateZ(-110deg); opacity: 0; }
}
.confetti-container {
  position: absolute;
  inset: 0;
  pointer-events: none;
  z-index: 10;
  overflow: hidden;
  opacity: 0;
  transition: opacity 1.2s ease-in;
  perspective: 200px;
}
.confetti-container.active { opacity: 1; }
.confetti-piece {
  position: absolute;
  width: 8px;
  height: 5px;
  opacity: 0;
  top: -8%;
  border-radius: 1px;
  transform-style: preserve-3d;
}
/* Co-prime durations + full-cycle delays = persistent even stream */
.confetti-container.active .cf-1  { animation: cf-drift-1 3.7s linear infinite; animation-delay: 0.0s; }
.confetti-container.active .cf-2  { animation: cf-drift-2 4.1s linear infinite; animation-delay: 0.7s; }
.confetti-container.active .cf-3  { animation: cf-drift-3 4.9s linear infinite; animation-delay: 1.4s; }
.confetti-container.active .cf-4  { animation: cf-drift-4 5.3s linear infinite; animation-delay: 2.1s; }
.confetti-container.active .cf-5  { animation: cf-drift-1 5.7s linear infinite; animation-delay: 2.8s; }
.confetti-container.active .cf-6  { animation: cf-drift-2 6.1s linear infinite; animation-delay: 3.5s; }
.confetti-container.active .cf-7  { animation: cf-drift-3 3.9s linear infinite; animation-delay: 0.35s; }
.confetti-container.active .cf-8  { animation: cf-drift-4 4.3s linear infinite; animation-delay: 1.05s; }
.confetti-container.active .cf-9  { animation: cf-drift-1 5.1s linear infinite; animation-delay: 1.75s; }
.confetti-container.active .cf-10 { animation: cf-drift-2 6.7s linear infinite; animation-delay: 2.45s; }
.confetti-container.active .cf-11 { animation: cf-drift-3 4.7s linear infinite; animation-delay: 3.15s; }
.confetti-container.active .cf-12 { animation: cf-drift-4 5.9s linear infinite; animation-delay: 3.85s; }
.confetti-container.active .cf-13 { animation: cf-drift-1 6.3s linear infinite; animation-delay: 4.2s; }
.confetti-container.active .cf-14 { animation: cf-drift-2 3.7s linear infinite; animation-delay: 4.55s; }
.confetti-container.active .cf-15 { animation: cf-drift-3 7.1s linear infinite; animation-delay: 4.9s; }
.confetti-container.active .cf-16 { animation: cf-drift-4 4.1s linear infinite; animation-delay: 5.2s; }
.confetti-container.active .cf-17 { animation: cf-drift-1 5.3s linear infinite; animation-delay: 0.5s; }
.confetti-container.active .cf-18 { animation: cf-drift-2 4.9s linear infinite; animation-delay: 1.55s; }
.confetti-container.active .cf-19 { animation: cf-drift-3 6.1s linear infinite; animation-delay: 2.65s; }
.confetti-container.active .cf-20 { animation: cf-drift-4 5.7s linear infinite; animation-delay: 5.5s; }
.cf-1  { left: 5%;  background: #D4AF37; }
.cf-2  { left: 12%; background: #FFD700; }
.cf-3  { left: 20%; background: #FFFFFF; }
.cf-4  { left: 28%; background: #D4AF37; }
.cf-5  { left: 35%; background: #FFD700; }
.cf-6  { left: 42%; background: #F9E29B; }
.cf-7  { left: 50%; background: #D4AF37; }
.cf-8  { left: 58%; background: #FFFFFF; }
.cf-9  { left: 65%; background: #FFD700; }
.cf-10 { left: 72%; background: #D4AF37; }
.cf-11 { left: 80%; background: #F9E29B; }
.cf-12 { left: 88%; background: #FFD700; }
.cf-13 { left: 95%; background: #D4AF37; }
.cf-14 { left: 8%;  background: #FFFFFF; width: 6px; height: 6px; }
.cf-15 { left: 18%; background: #D4AF37; width: 10px; height: 4px; }
.cf-16 { left: 32%; background: #FFD700; width: 6px; height: 6px; }
.cf-17 { left: 45%; background: #F9E29B; width: 10px; height: 4px; }
.cf-18 { left: 55%; background: #D4AF37; }
.cf-19 { left: 75%; background: #FFFFFF; width: 6px; height: 6px; }
.cf-20 { left: 92%; background: #FFD700; width: 10px; height: 4px; }

/* Trophy & winner styling */
.trophy-icon {
  opacity: 0;
  transition: opacity 1.5s ease;
  font-size: 1.5rem;
  color: #D4AF37;
  filter: drop-shadow(0 0 5px rgba(212,175,55,0.5));
}
.trophy-icon.visible {
  opacity: 1;
  animation: pulse-gold 2s cubic-bezier(0.4, 0, 0.6, 1) infinite;
  animation-delay: 1.5s;
  animation-fill-mode: backwards;
}
.winner-glow .set-pip.bg-gold {
  box-shadow: 0 0 8px rgba(212,175,55,0.8);
}
.loser-dim {
  opacity: 0.5 !important;
  transition: opacity 0.6s ease;
}
.final-label {
  display: none;
  font-size: 10px;
  font-weight: 900;
  color: rgba(212,175,55,0.8);
  text-transform: uppercase;
  letter-spacing: 0.2em;
  margin-bottom: 2px;
}
.final-label.visible { display: block; }

body {
  min-height: 100dvh;
  background-color: #0a0a0a;
  margin: 0;
  padding: 0;
  font-family: "Roboto Condensed", sans-serif;
  color: white;
  overflow: hidden;
}
/* Serve indicator - static with fade transition */
.serve-indicator {
  transition: opacity 0.3s ease-in-out;
}

/* Bubble animations - slide from behind scoreboard */
.bubble-container {
  position: relative;
  display: flex;
  justify-content: center;
  margin-top: -2px;
  z-index: 5;
  height: 32px;
}
.bubble-bar {
  transition: transform 0.4s cubic-bezier(0.4, 0, 0.2, 1), opacity 0.3s ease;
  position: absolute;
  top: 0;
  will-change: transform, opacity;
  backface-visibility: hidden;
  -webkit-backface-visibility: hidden;
}
.bubble-bar.hidden-up {
  transform: translateY(-120%) translateZ(0);
  opacity: 0;
  pointer-events: none;
}
.bubble-bar.visible {
  transform: translateY(0) translateZ(0);
  opacity: 1;
}

/* Scoring element slide transitions */
#scoring-content {
  display: flex;
  align-items: center;
  width: 100%;
  height: 100%;
  transition: opacity 0.1s ease;
}
#scoring-content > * {
  transition: transform 0.5s cubic-bezier(0.4, 0, 0.2, 1), opacity 0.4s ease;
}
#scoring-content.slide-out > * {
  opacity: 0;
}
#scoring-content.slide-out #team1-section {
  transform: translateX(30%);
}
#scoring-content.slide-out #team2-section {
  transform: translateX(-30%);
}

/* Scorebug width transition */
#scorebug {
  transition: width 0.5s cubic-bezier(0.4, 0, 0.2, 1);
}

/* Intermission content inside scorebug */
#intermission-content {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  opacity: 0;
  pointer-events: none;
  transition: opacity 0.3s ease;
}
#intermission-content.visible {
  opacity: 1;
  pointer-events: auto;
}

/* Status bubble for intermission */
.status-bubble {
  background: rgba(0, 0, 0, 0.9);
  border: 1px solid rgba(212, 175, 55, 0.5);
  border-top: none;
  border-radius: 0 0 0.5rem 0.5rem;
  animation: status-pulse 2s infinite ease-in-out;
}
/* Stale data indicator */
#stale-indicator {
  position: fixed;
  top: 8px;
  right: 8px;
  font-size: 10px;
  font-weight: 700;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  padding: 3px 8px;
  border-radius: 4px;
  opacity: 0;
  transition: opacity 0.5s ease;
  pointer-events: none;
  z-index: 100;
}
#stale-indicator.stale {
  opacity: 1;
  background: rgba(245, 158, 11, 0.3);
  color: #FBBF24;
  animation: stale-pulse 2s ease-in-out infinite;
}
#stale-indicator.lost {
  opacity: 1;
  background: rgba(239, 68, 68, 0.3);
  color: #F87171;
}
@keyframes stale-pulse {
  0%, 100% { opacity: 0.7; }
  50% { opacity: 1; }
}
#scorebug.stale-border {
  border-color: rgba(245, 158, 11, 0.4) !important;
  box-shadow: 0 8px 30px rgb(0,0,0,0.8), 0 0 8px rgba(245, 158, 11, 0.2) !important;
}
/* Connecting fallback */
#connecting-indicator {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  opacity: 0;
  pointer-events: none;
  transition: opacity 0.5s ease;
  z-index: 50;
}
#connecting-indicator.visible {
  opacity: 1;
}
#connecting-indicator span {
  font-size: 0.875rem;
  font-weight: 700;
  letter-spacing: 0.15em;
  color: rgba(255,255,255,0.4);
  animation: connecting-pulse 2s ease-in-out infinite;
}
@keyframes connecting-pulse {
  0%, 100% { opacity: 0.3; }
  50% { opacity: 0.7; }
}

/* ===== LAYOUT SYSTEM ===== */

/* Center layout (default) - upper third bar */
body.layout-center #scorebug { display: flex; }
body.layout-center #trad-board { display: none !important; }

/* Traditional layouts - hide center bar, show table */
body.layout-top-left #scorebug { display: none !important; }
body.layout-bottom-left #scorebug { display: none !important; }
body.layout-top-left #trad-board { display: flex !important; }
body.layout-bottom-left #trad-board { display: flex !important; }
/* Also hide center intermission content in trad layouts */
body.layout-top-left #intermission-content { display: none !important; }
body.layout-bottom-left #intermission-content { display: none !important; }

/* Reposition wrapper for traditional layouts */
body.layout-top-left {
  align-items: flex-start !important;
  padding-top: 0 !important;
}
body.layout-top-left > div:not(#stale-indicator) {
  align-items: flex-start !important;
  padding: 0 !important;
  max-width: none !important;
}
body.layout-bottom-left {
  align-items: flex-start !important;
  justify-content: flex-end !important;
  padding-top: 0 !important;
  padding-bottom: 0 !important;
}
body.layout-bottom-left > div:not(#stale-indicator) {
  align-items: flex-start !important;
  padding: 0 !important;
  max-width: none !important;
}

/* Top-left: board fixed to corner, bubbles drop DOWN below board */
body.layout-top-left #trad-board {
  position: fixed;
  top: 1rem;
  left: 1rem;
}
body.layout-top-left .bubble-container {
  position: fixed;
  left: 1rem;
  top: calc(1rem + var(--trad-board-height, 5.5rem));
  justify-content: center;
  margin: 0;
  z-index: 19;
  height: 28px;
  width: var(--trad-board-width, auto);
}
body.layout-top-left .bubble-bar {
  top: 0;
  max-width: calc(100% - 2px);
  box-sizing: border-box;
}
body.layout-top-left .bubble-bar.hidden-up {
  transform: translateY(-120%) translateZ(0);
}
body.layout-top-left .bubble-bar.visible {
  transform: translateY(0) translateZ(0);
}

/* Bottom-left: board fixed to corner, bubbles pop UP above board */
body.layout-bottom-left #trad-board {
  position: fixed;
  bottom: 1rem;
  left: 1rem;
}
body.layout-bottom-left .bubble-container {
  position: fixed;
  left: 1rem;
  bottom: calc(1rem + var(--trad-board-height, 5.5rem));
  justify-content: center;
  margin: 0;
  z-index: 19;
  height: 28px;
  width: var(--trad-board-width, auto);
}
/* Invert bubble direction for bottom-left: pop UP */
body.layout-bottom-left .bubble-bar {
  top: auto;
  bottom: 0;
  max-width: calc(100% - 2px);
  box-sizing: border-box;
}
body.layout-bottom-left .bubble-bar.hidden-up {
  transform: translateY(120%) translateZ(0);
}
body.layout-bottom-left .bubble-bar.visible {
  transform: translateY(0) translateZ(0);
}
/* Invert border-radius for upward bubbles */
body.layout-bottom-left .bubble-bar {
  border-radius: 0.5rem 0.5rem 0 0;
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-bottom: none;
}
body.layout-bottom-left .status-bubble {
  border-radius: 0.5rem 0.5rem 0 0;
  border-bottom: none;
  border-top: 1px solid rgba(212, 175, 55, 0.5);
}

/* Trad-layout bubble bars: compact, centered, fit to board width */
body.layout-top-left .bubble-bar,
body.layout-bottom-left .bubble-bar {
  padding: 0.2rem 0.4rem !important;
  gap: 0.25rem !important;
  white-space: nowrap;
  overflow: hidden;
  width: 100%;
  box-sizing: border-box;
  justify-content: center;
  left: 0;
  right: 0;
}
body.layout-top-left .bubble-bar span,
body.layout-bottom-left .bubble-bar span {
  letter-spacing: 0 !important;
  font-size: inherit !important;
}
body.layout-top-left .bubble-bar svg,
body.layout-bottom-left .bubble-bar svg {
  width: 10px !important;
  height: 10px !important;
  flex-shrink: 0;
}

/* Layout fade transition */
.layout-fading {
  opacity: 0 !important;
  transition: opacity 0.35s ease !important;
  will-change: opacity;
}

/* GPU acceleration for overlay wrapper */
#overlay-wrapper {
  will-change: opacity;
  backface-visibility: hidden;
  -webkit-backface-visibility: hidden;
}

/* ===== TRADITIONAL SCOREBOARD ===== */
.trad-board {
  display: none;
  flex-direction: column;
  width: auto;
  border-radius: 0.375rem;
  box-shadow: 0 8px 30px rgba(0,0,0,0.8);
  overflow: hidden;
  z-index: 20;
  position: relative;
}
.trad-row {
  display: flex;
  align-items: center;
  height: 2.6rem;
  padding: 0 0.5rem;
  gap: 0;
  position: relative;
}
.trad-divider {
  height: 1px;
  background: rgba(255,255,255,0.1);
}
.trad-serve {
  width: 22px;
  height: 22px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
  opacity: 0;
  margin-right: 0.25rem;
}
.trad-serve.active { opacity: 1; }
.trad-seed {
  font-size: 0.7rem;
  font-weight: 700;
  color: rgba(212,175,55,0.8);
  min-width: 0;
  text-align: center;
  flex-shrink: 0;
}
.trad-seed:not(:empty) {
  margin-right: 0.25rem;
}
.trad-name {
  font-size: 0.95rem;
  font-weight: 800;
  text-transform: uppercase;
  letter-spacing: -0.025em;
  color: rgba(255,255,255,0.95);
  font-style: italic;
  white-space: nowrap;
  padding-right: 0.6rem;
  flex-shrink: 0;
  /* Width set by JS to equalize both rows */
}
.trad-sets {
  display: flex;
  align-items: center;
  gap: 0;
  flex-shrink: 0;
}
.trad-set-cell {
  font-size: 0.85rem;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  min-width: 1.8rem;
  text-align: center;
  padding: 0 0.2rem;
  color: rgba(255,255,255,0.4);
  border-left: 1px solid rgba(255,255,255,0.08);
}
.trad-set-cell.set-winner {
  font-weight: 800;
  color: rgba(255,255,255,0.7);
}
.trad-set-cell.set-loser {
  color: rgba(255,255,255,0.25);
}
.trad-current-score {
  font-size: 1.3rem;
  font-weight: 900;
  background: linear-gradient(180deg, #F9E29B 0%, #D4AF37 100%);
  -webkit-background-clip: text;
  background-clip: text;
  -webkit-text-fill-color: transparent;
  font-variant-numeric: tabular-nums;
  font-style: italic;
  min-width: 0;
  text-align: center;
  border-left: 1px solid rgba(255,255,255,0.15);
  padding: 0 0.35rem;
  flex-shrink: 0;
  line-height: 2.6rem;
  transition: transform 0.15s ease-out, opacity 0.15s ease-out;
}
.trad-trophy {
  font-size: 1.1rem;
  flex-shrink: 0;
  width: 0;
  overflow: hidden;
  transition: width 0.5s ease, margin 0.5s ease;
  margin-left: 0;
}
.trad-trophy.visible {
  width: 22px;
  margin-left: 0.25rem;
}

/* Confetti for traditional board */
.trad-confetti {
  position: absolute;
  inset: 0;
  pointer-events: none;
  z-index: 10;
  overflow: hidden;
  opacity: 0;
  transition: opacity 1.2s ease-in;
  perspective: 200px;
}
.trad-confetti.active { opacity: 1; }

/* Trophy reuse existing .trophy-icon styles */
.trad-winner-glow {
  background: linear-gradient(180deg, rgba(212,175,55,0.15) 0%, rgba(212,175,55,0.05) 100%) !important;
}
.trad-loser-dim {
  opacity: 0.45 !important;
}

/* Traditional board intermission: hide scores, show names */
.trad-board.trad-intermission .trad-current-score,
.trad-board.trad-intermission .trad-sets,
.trad-board.trad-intermission .trad-serve,
.trad-board.trad-intermission .trad-trophy,
.trad-board.trad-intermission .trad-confetti {
  visibility: hidden;
}
</style>
</head>
<body style="display: flex; flex-direction: column; align-items: center; padding-top: 2rem;">

<div id="stale-indicator"></div>

<div id="overlay-wrapper" style="display: flex; flex-direction: column; align-items: center; width: 100%; max-width: 900px; padding: 0 1rem;">
  <!-- Main Scoreboard -->
  <div id="scorebug" class="carbon-bar" style="width: 100%; height: 4rem; border-radius: 0.375rem; display: flex; align-items: center; box-shadow: 0 8px 30px rgb(0,0,0,0.8); position: relative; overflow: hidden; z-index: 20;">

    <!-- Connecting fallback -->
    <div id="connecting-indicator"><span>Connecting...</span></div>

    <!-- Scoring Content Layer -->
    <div id="scoring-content">
      <!-- Left Team Section -->
      <div id="team1-section" style="flex: 1; display: flex; align-items: center; justify-content: space-between; padding: 0 1.5rem; height: 100%; position: relative; overflow: hidden;">
        <div id="confetti-left" class="confetti-container">
          <div class="confetti-piece cf-1"></div><div class="confetti-piece cf-2"></div>
          <div class="confetti-piece cf-3"></div><div class="confetti-piece cf-4"></div>
          <div class="confetti-piece cf-5"></div><div class="confetti-piece cf-6"></div>
          <div class="confetti-piece cf-7"></div><div class="confetti-piece cf-8"></div>
          <div class="confetti-piece cf-9"></div><div class="confetti-piece cf-10"></div>
          <div class="confetti-piece cf-11"></div><div class="confetti-piece cf-12"></div>
          <div class="confetti-piece cf-13"></div><div class="confetti-piece cf-14"></div>
          <div class="confetti-piece cf-15"></div><div class="confetti-piece cf-16"></div>
          <div class="confetti-piece cf-17"></div><div class="confetti-piece cf-18"></div>
          <div class="confetti-piece cf-19"></div><div class="confetti-piece cf-20"></div>
        </div>
        <div style="display: flex; align-items: flex-start; gap: 0.5rem; position: relative; z-index: 20;">
          <span id="trophy-left" class="trophy-icon"><svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M19 5h-2V3H7v2H5c-1.1 0-2 .9-2 2v1c0 2.55 1.92 4.63 4.39 4.94.63 1.5 1.98 2.63 3.61 2.96V19H7v2h10v-2h-4v-3.1c1.63-.33 2.98-1.46 3.61-2.96C19.08 12.63 21 10.55 21 8V7c0-1.1-.9-2-2-2zM5 8V7h2v3.82C5.84 10.4 5 9.3 5 8zm14 0c0 1.3-.84 2.4-2 2.82V7h2v1z"/></svg></span>
          <span id="seed1" style="font-size: 0.75rem; font-weight: 700; color: rgba(212,175,55,0.8); margin-top: 0.1rem; min-width: 1rem; text-align: center;"></span>
          <div style="display: flex; flex-direction: column; justify-content: center;">
            <span id="t1" style="font-size: 1.125rem; font-weight: 800; text-transform: uppercase; letter-spacing: -0.025em; color: rgba(255,255,255,0.95); line-height: 1; margin-bottom: 0.375rem; font-style: italic;">Team 1</span>
            <div id="pips1" style="display: flex; gap: 0.375rem;">
              <div class="set-pip bg-gold-muted"></div>
              <div class="set-pip bg-gold-muted"></div>
            </div>
          </div>
          <span id="serve-left" class="serve-indicator" style="opacity: 0; margin-top: -0.1rem; display: inline-flex;"><svg width="24" height="24" viewBox="0 0 24 24" fill="#D4AF37"><circle cx="12" cy="12" r="10" fill="none" stroke="#D4AF37" stroke-width="2"/><path d="M6.5 3.5c3.5 2 5 5.5 5 8.5" fill="none" stroke="#D4AF37" stroke-width="1.5"/><path d="M17.5 20.5c-3.5-2-5-5.5-5-8.5" fill="none" stroke="#D4AF37" stroke-width="1.5"/><path d="M2.5 10c3 1.5 7 1.5 10 0s7-1.5 10 0" fill="none" stroke="#D4AF37" stroke-width="1.5"/></svg></span>
        </div>
        <div class="score-container" style="position: relative; z-index: 20;">
          <span id="sc1" class="score-text">0</span>
        </div>
      </div>

      <div class="center-divider" style="width: 1px; height: 2.5rem; background: rgba(255,255,255,0.2); flex-shrink: 0;"></div>

      <!-- Set Indicator -->
      <div id="set-indicator" style="padding: 0 1.5rem; display: flex; flex-direction: column; align-items: center; justify-content: center; min-width: 70px; flex-shrink: 0;">
        <span id="set-label" style="font-size: 10px; font-weight: 900; color: rgba(212,175,55,0.8); text-transform: uppercase; letter-spacing: 0.2em; margin-bottom: 2px;">SET</span>
        <span id="set-num" style="font-size: 1.25rem; font-weight: 900; color: rgba(255,255,255,0.9); line-height: 1;">1</span>
      </div>

      <div class="center-divider" style="width: 1px; height: 2.5rem; background: rgba(255,255,255,0.2); flex-shrink: 0;"></div>

      <!-- Right Team Section -->
      <div id="team2-section" style="flex: 1; display: flex; align-items: center; justify-content: space-between; padding: 0 1.5rem; height: 100%; position: relative; overflow: hidden;">
        <div id="confetti-right" class="confetti-container">
          <div class="confetti-piece cf-1"></div><div class="confetti-piece cf-2"></div>
          <div class="confetti-piece cf-3"></div><div class="confetti-piece cf-4"></div>
          <div class="confetti-piece cf-5"></div><div class="confetti-piece cf-6"></div>
          <div class="confetti-piece cf-7"></div><div class="confetti-piece cf-8"></div>
          <div class="confetti-piece cf-9"></div><div class="confetti-piece cf-10"></div>
          <div class="confetti-piece cf-11"></div><div class="confetti-piece cf-12"></div>
          <div class="confetti-piece cf-13"></div><div class="confetti-piece cf-14"></div>
          <div class="confetti-piece cf-15"></div><div class="confetti-piece cf-16"></div>
          <div class="confetti-piece cf-17"></div><div class="confetti-piece cf-18"></div>
          <div class="confetti-piece cf-19"></div><div class="confetti-piece cf-20"></div>
        </div>
        <div class="score-container" style="position: relative; z-index: 20;">
          <span id="sc2" class="score-text">0</span>
        </div>
        <div style="display: flex; align-items: flex-start; gap: 0.5rem; text-align: right; position: relative; z-index: 20;">
          <span id="serve-right" class="serve-indicator" style="opacity: 0; margin-top: -0.1rem; display: inline-flex;"><svg width="24" height="24" viewBox="0 0 24 24" fill="#D4AF37"><circle cx="12" cy="12" r="10" fill="none" stroke="#D4AF37" stroke-width="2"/><path d="M6.5 3.5c3.5 2 5 5.5 5 8.5" fill="none" stroke="#D4AF37" stroke-width="1.5"/><path d="M17.5 20.5c-3.5-2-5-5.5-5-8.5" fill="none" stroke="#D4AF37" stroke-width="1.5"/><path d="M2.5 10c3 1.5 7 1.5 10 0s7-1.5 10 0" fill="none" stroke="#D4AF37" stroke-width="1.5"/></svg></span>
          <div style="display: flex; flex-direction: column; align-items: flex-end; justify-content: center;">
            <span id="t2" style="font-size: 1.125rem; font-weight: 800; text-transform: uppercase; letter-spacing: -0.025em; color: rgba(255,255,255,0.95); line-height: 1; margin-bottom: 0.375rem; font-style: italic;">Team 2</span>
            <div id="pips2" style="display: flex; gap: 0.375rem;">
              <div class="set-pip bg-gold-muted"></div>
              <div class="set-pip bg-gold-muted"></div>
            </div>
          </div>
          <span id="seed2" style="font-size: 0.75rem; font-weight: 700; color: rgba(212,175,55,0.8); margin-top: 0.1rem; min-width: 1rem; text-align: center;"></span>
          <span id="trophy-right" class="trophy-icon"><svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M19 5h-2V3H7v2H5c-1.1 0-2 .9-2 2v1c0 2.55 1.92 4.63 4.39 4.94.63 1.5 1.98 2.63 3.61 2.96V19H7v2h10v-2h-4v-3.1c1.63-.33 2.98-1.46 3.61-2.96C19.08 12.63 21 10.55 21 8V7c0-1.1-.9-2-2-2zM5 8V7h2v3.82C5.84 10.4 5 9.3 5 8zm14 0c0 1.3-.84 2.4-2 2.82V7h2v1z"/></svg></span>
        </div>
      </div>
    </div>

    <!-- Intermission Content Layer (overlaid, hidden by default) -->
    <div id="intermission-content">
      <div id="int-team1-container" style="display: flex; align-items: center; justify-content: center; flex-shrink: 0;">
        <span id="int-team1" style="font-size: 1.25rem; font-weight: 900; text-transform: uppercase; letter-spacing: -0.025em; color: white; font-style: italic; white-space: nowrap; transform: translateX(30px); transition: transform 0.5s cubic-bezier(0.4,0,0.2,1), opacity 0.5s ease; opacity: 0;">Team 1</span>
      </div>
      <div id="int-vs" style="display: flex; align-items: center; flex-shrink: 0; margin: 0 1rem; opacity: 0; transition: opacity 0.5s ease;">
        <div style="width: 1px; height: 1.5rem; background: rgba(255,255,255,0.2);"></div>
        <span style="font-size: 1.125rem; font-weight: 900; font-style: italic; letter-spacing: 0.15em; padding: 0 1rem; background: linear-gradient(180deg, #F9E29B 0%, #D4AF37 100%); -webkit-background-clip: text; -webkit-text-fill-color: transparent;">VS</span>
        <div style="width: 1px; height: 1.5rem; background: rgba(255,255,255,0.2);"></div>
      </div>
      <div id="int-team2-container" style="display: flex; align-items: center; justify-content: center; flex-shrink: 0;">
        <span id="int-team2" style="font-size: 1.25rem; font-weight: 900; text-transform: uppercase; letter-spacing: -0.025em; color: white; font-style: italic; white-space: nowrap; transform: translateX(-30px); transition: transform 0.5s cubic-bezier(0.4,0,0.2,1), opacity 0.5s ease; opacity: 0;">Team 2</span>
      </div>
    </div>

    <!-- Bottom Accent Line -->
    <div style="position: absolute; bottom: 0; left: 0; right: 0; height: 2px; background: linear-gradient(90deg, transparent, rgba(212,175,55,0.5), transparent); z-index: 30;"></div>
  </div>

  <!-- Traditional Scoreboard (hidden by default, shown in top-left/bottom-left layouts) -->
  <div id="trad-board" class="trad-board carbon-bar" style="display:none;">
    <div id="trad-row1" class="trad-row">
      <div id="trad-confetti1" class="trad-confetti confetti-container">
        <div class="confetti-piece cf-1"></div><div class="confetti-piece cf-2"></div>
        <div class="confetti-piece cf-3"></div><div class="confetti-piece cf-4"></div>
        <div class="confetti-piece cf-5"></div><div class="confetti-piece cf-6"></div>
        <div class="confetti-piece cf-7"></div><div class="confetti-piece cf-8"></div>
        <div class="confetti-piece cf-9"></div><div class="confetti-piece cf-10"></div>
      </div>
      <span id="trad-serve1" class="trad-serve"><svg width="18" height="18" viewBox="0 0 24 24" fill="#D4AF37"><circle cx="12" cy="12" r="10" fill="none" stroke="#D4AF37" stroke-width="2"/><path d="M6.5 3.5c3.5 2 5 5.5 5 8.5" fill="none" stroke="#D4AF37" stroke-width="1.5"/><path d="M17.5 20.5c-3.5-2-5-5.5-5-8.5" fill="none" stroke="#D4AF37" stroke-width="1.5"/><path d="M2.5 10c3 1.5 7 1.5 10 0s7-1.5 10 0" fill="none" stroke="#D4AF37" stroke-width="1.5"/></svg></span>
      <span id="trad-seed1" class="trad-seed"></span>
      <span id="trad-t1" class="trad-name">Team 1</span>
      <div id="trad-sets1" class="trad-sets"></div>
      <span id="trad-sc1" class="trad-current-score score-text">0</span>
      <span id="trad-trophy1" class="trophy-icon trad-trophy"><svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor"><path d="M19 5h-2V3H7v2H5c-1.1 0-2 .9-2 2v1c0 2.55 1.92 4.63 4.39 4.94.63 1.5 1.98 2.63 3.61 2.96V19H7v2h10v-2h-4v-3.1c1.63-.33 2.98-1.46 3.61-2.96C19.08 12.63 21 10.55 21 8V7c0-1.1-.9-2-2-2zM5 8V7h2v3.82C5.84 10.4 5 9.3 5 8zm14 0c0 1.3-.84 2.4-2 2.82V7h2v1z"/></svg></span>
    </div>
    <div class="trad-divider"></div>
    <div id="trad-row2" class="trad-row">
      <div id="trad-confetti2" class="trad-confetti confetti-container">
        <div class="confetti-piece cf-1"></div><div class="confetti-piece cf-2"></div>
        <div class="confetti-piece cf-3"></div><div class="confetti-piece cf-4"></div>
        <div class="confetti-piece cf-5"></div><div class="confetti-piece cf-6"></div>
        <div class="confetti-piece cf-7"></div><div class="confetti-piece cf-8"></div>
        <div class="confetti-piece cf-9"></div><div class="confetti-piece cf-10"></div>
      </div>
      <span id="trad-serve2" class="trad-serve"><svg width="18" height="18" viewBox="0 0 24 24" fill="#D4AF37"><circle cx="12" cy="12" r="10" fill="none" stroke="#D4AF37" stroke-width="2"/><path d="M6.5 3.5c3.5 2 5 5.5 5 8.5" fill="none" stroke="#D4AF37" stroke-width="1.5"/><path d="M17.5 20.5c-3.5-2-5-5.5-5-8.5" fill="none" stroke="#D4AF37" stroke-width="1.5"/><path d="M2.5 10c3 1.5 7 1.5 10 0s7-1.5 10 0" fill="none" stroke="#D4AF37" stroke-width="1.5"/></svg></span>
      <span id="trad-seed2" class="trad-seed"></span>
      <span id="trad-t2" class="trad-name">Team 2</span>
      <div id="trad-sets2" class="trad-sets"></div>
      <span id="trad-sc2" class="trad-current-score score-text">0</span>
      <span id="trad-trophy2" class="trophy-icon trad-trophy"><svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor"><path d="M19 5h-2V3H7v2H5c-1.1 0-2 .9-2 2v1c0 2.55 1.92 4.63 4.39 4.94.63 1.5 1.98 2.63 3.61 2.96V19H7v2h10v-2h-4v-3.1c1.63-.33 2.98-1.46 3.61-2.96C19.08 12.63 21 10.55 21 8V7c0-1.1-.9-2-2-2zM5 8V7h2v3.82C5.84 10.4 5 9.3 5 8zm14 0c0 1.3-.84 2.4-2 2.82V7h2v1z"/></svg></span>
    </div>
    <!-- Bottom accent line -->
    <div style="position: absolute; bottom: 0; left: 0; right: 0; height: 2px; background: linear-gradient(90deg, transparent, rgba(212,175,55,0.5), transparent); z-index: 30;"></div>
  </div>

  <!-- Bubble Container (holds social bar OR next match bar) -->
  <div class="bubble-container">
    <!-- Social Media Bar (default visible) -->
    <div id="social-bar" class="bubble-bar visible" style="padding: 0.375rem 1.25rem; display: flex; align-items: center; gap: 0.75rem; box-shadow: 0 4px 12px rgba(0,0,0,0.5);">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="#1877F2"><path d="M24 12.073c0-6.627-5.373-12-12-12s-12 5.373-12 12c0 5.99 4.388 10.954 10.125 11.854v-8.385H7.078v-3.47h3.047V9.43c0-3.007 1.792-4.669 4.533-4.669 1.312 0 2.686.235 2.686.235v2.953H15.83c-1.491 0-1.956.925-1.956 1.874v2.25h3.328l-.532 3.47h-2.796v8.385C19.612 23.027 24 18.062 24 12.073z"/></svg>
      <svg width="14" height="14" viewBox="0 0 24 24"><defs><radialGradient id="ig" cx="30%" cy="107%" r="150%"><stop offset="0%" stop-color="#fdf497"/><stop offset="5%" stop-color="#fdf497"/><stop offset="45%" stop-color="#fd5949"/><stop offset="60%" stop-color="#d6249f"/><stop offset="90%" stop-color="#285AEB"/></radialGradient></defs><path fill="url(#ig)" d="M12 2.163c3.204 0 3.584.012 4.85.07 3.252.148 4.771 1.691 4.919 4.919.058 1.265.069 1.645.069 4.849 0 3.205-.012 3.584-.069 4.849-.149 3.225-1.664 4.771-4.919 4.919-1.266.058-1.644.07-4.85.07-3.204 0-3.584-.012-4.849-.07-3.26-.149-4.771-1.699-4.919-4.92-.058-1.265-.07-1.644-.07-4.849 0-3.204.013-3.583.07-4.849.149-3.227 1.664-4.771 4.919-4.919 1.266-.057 1.645-.069 4.849-.069zM12 0C8.741 0 8.333.014 7.053.072 2.695.272.273 2.69.073 7.052.014 8.333 0 8.741 0 12c0 3.259.014 3.668.072 4.948.2 4.358 2.618 6.78 6.98 6.98C8.333 23.986 8.741 24 12 24c3.259 0 3.668-.014 4.948-.072 4.354-.2 6.782-2.618 6.979-6.98.059-1.28.073-1.689.073-4.948 0-3.259-.014-3.667-.072-4.947-.196-4.354-2.617-6.78-6.979-6.98C15.668.014 15.259 0 12 0zm0 5.838a6.162 6.162 0 100 12.324 6.162 6.162 0 000-12.324zM12 16a4 4 0 110-8 4 4 0 010 8zm6.406-11.845a1.44 1.44 0 100 2.881 1.44 1.44 0 000-2.881z"/></svg>
      <svg width="14" height="14" viewBox="0 0 24 24" fill="#FF0000"><path d="M23.498 6.186a3.016 3.016 0 00-2.122-2.136C19.505 3.545 12 3.545 12 3.545s-7.505 0-9.377.505A3.017 3.017 0 00.502 6.186C0 8.07 0 12 0 12s0 3.93.502 5.814a3.016 3.016 0 002.122 2.136c1.871.505 9.376.505 9.376.505s7.505 0 9.377-.505a3.015 3.015 0 002.122-2.136C24 15.93 24 12 24 12s0-3.93-.502-5.814zM9.545 15.568V8.432L15.818 12l-6.273 3.568z"/></svg>
      <span style="font-size: 0.75rem; font-weight: 600; letter-spacing: 0.025em; color: rgba(255,255,255,0.9);">@BeachVolleyballMedia</span>
    </div>
    
    <!-- Next Match Bar (hidden by default) -->
    <div id="next-bar" class="bubble-bar hidden-up" style="padding: 0.375rem 1.25rem; display: flex; align-items: center; gap: 0.5rem; box-shadow: 0 4px 12px rgba(0,0,0,0.5); white-space: nowrap; flex-wrap: nowrap;">
      <span style="font-size: 10px; font-weight: 900; color: #D4AF37; text-transform: uppercase; letter-spacing: 0.05em; flex-shrink: 0;">Next</span>
      <span style="color: rgba(255,255,255,0.3); flex-shrink: 0;">|</span>
      <span id="next-teams" style="font-size: 0.75rem; font-weight: 600; letter-spacing: 0.025em; color: rgba(255,255,255,0.95); text-transform: uppercase; white-space: nowrap;">Loading...</span>
    </div>

    <!-- Intermission Status Bubble (hidden by default) -->
    <div id="int-status-bar" class="status-bubble bubble-bar hidden-up" style="padding: 0.25rem 1.25rem; box-shadow: 0 4px 12px rgba(0,0,0,0.5); white-space: nowrap;">
      <span style="font-size: 9px; font-weight: 900; letter-spacing: 0.2em; text-transform: uppercase; background: linear-gradient(180deg, #F9E29B 0%, #D4AF37 100%); -webkit-background-clip: text; -webkit-text-fill-color: transparent; white-space: nowrap;">Match Starting Soon</span>
    </div>
  </div>
</div>

<script>
const SRC = "/score.json";
const NEXT_SRC = "/next.json";
const POLL_MS = 1000;
let POST_MATCH_HOLD_MS = 180000; // 3 minutes hold after match ends (updated from server)
const SCORING_WIDTH = '100%';

// Overlay State Machine: 'scoring' | 'postmatch' | 'intermission'
let overlayState = 'intermission'; // Start in intermission until scoring data arrives
let postMatchTimer = null;
let matchFinishedAt = null;
let lastMatchId = null;
let firstLoad = true;

// Animation state
var lastTriggerScore = -1;
var animationInProgress = false;
var nextMatchTimer = null;
var transitionInProgress = false;
var transitionSafetyTimer = null;
var celebrationActive = false;

// Stale data tracking
var lastDataChangeTime = Date.now();
var lastDataJSON = '';
var consecutiveFetchErrors = 0;
var staleIndicatorState = 'fresh'; // 'fresh' | 'stale' | 'lost'

// Safety: ensure transitionInProgress never gets permanently stuck
function beginTransition() {
  transitionInProgress = true;
  clearTimeout(transitionSafetyTimer);
  transitionSafetyTimer = setTimeout(function() {
    if (transitionInProgress) {
      console.log('[Overlay] Safety: forcing transitionInProgress=false after 10s');
      transitionInProgress = false;
    }
  }, 10000);
}
function endTransition() {
  transitionInProgress = false;
  clearTimeout(transitionSafetyTimer);
}

// Match change detection - track current match to detect manual/auto advances
var currentMatchTeam1 = '';
var currentMatchTeam2 = '';
var currentMatchNumber = '';
var pendingMatchChange = null; // { team1, team2, data } when match change detected

// DOM refs
const scorebug = document.getElementById('scorebug');
const scoringContent = document.getElementById('scoring-content');
const intermissionContent = document.getElementById('intermission-content');
const socialBar = document.getElementById('social-bar');
const nextBar = document.getElementById('next-bar');
const nextTeamsEl = document.getElementById('next-teams');
const intTeam1 = document.getElementById('int-team1');
const intTeam2 = document.getElementById('int-team2');
const intTeam1Container = document.getElementById('int-team1-container');
const intTeam2Container = document.getElementById('int-team2-container');
const intVs = document.getElementById('int-vs');
const intStatusBar = document.getElementById('int-status-bar');
const t1El = document.getElementById('t1');
const t2El = document.getElementById('t2');
const seed1El = document.getElementById('seed1');
const seed2El = document.getElementById('seed2');
const sc1El = document.getElementById('sc1');
const sc2El = document.getElementById('sc2');
const setNumEl = document.getElementById('set-num');
const staleIndicator = document.getElementById('stale-indicator');
const connectingIndicator = document.getElementById('connecting-indicator');

// Traditional scoreboard DOM refs
const tradBoard = document.getElementById('trad-board');
const tradT1 = document.getElementById('trad-t1');
const tradT2 = document.getElementById('trad-t2');
const tradSc1 = document.getElementById('trad-sc1');
const tradSc2 = document.getElementById('trad-sc2');
const tradSeed1 = document.getElementById('trad-seed1');
const tradSeed2 = document.getElementById('trad-seed2');
const tradServe1 = document.getElementById('trad-serve1');
const tradServe2 = document.getElementById('trad-serve2');
const tradSets1 = document.getElementById('trad-sets1');
const tradSets2 = document.getElementById('trad-sets2');
const tradTrophy1 = document.getElementById('trad-trophy1');
const tradTrophy2 = document.getElementById('trad-trophy2');
const tradRow1 = document.getElementById('trad-row1');
const tradRow2 = document.getElementById('trad-row2');
const tradConfetti1 = document.getElementById('trad-confetti1');
const tradConfetti2 = document.getElementById('trad-confetti2');

// Layout state
var currentLayout = 'center';
var layoutTransitionInProgress = false;
var lastSetHistoryKey = '';
var tradCelebrationActive = false;
var socialBarEnabled = true;

/* Stale data detection */
function updateStaleState(dataJSON) {
  if (dataJSON !== lastDataJSON) {
    lastDataJSON = dataJSON;
    lastDataChangeTime = Date.now();
    consecutiveFetchErrors = 0;
  }
  var elapsed = (Date.now() - lastDataChangeTime) / 1000;
  var newState = 'fresh';
  if (elapsed >= 60) {
    newState = 'lost';
  } else if (elapsed >= 15) {
    newState = 'stale';
  }
  if (newState !== staleIndicatorState) {
    staleIndicatorState = newState;
    applyStaleIndicator();
  }
}

function onFetchError() {
  consecutiveFetchErrors++;
  if (consecutiveFetchErrors >= 5) {
    connectingIndicator.classList.add('visible');
  }
  var elapsed = (Date.now() - lastDataChangeTime) / 1000;
  if (elapsed >= 60 && staleIndicatorState !== 'lost') {
    staleIndicatorState = 'lost';
    applyStaleIndicator();
  } else if (elapsed >= 15 && staleIndicatorState === 'fresh') {
    staleIndicatorState = 'stale';
    applyStaleIndicator();
  }
}

function applyStaleIndicator() {
  if (staleIndicatorState === 'fresh') {
    staleIndicator.className = '';
    staleIndicator.textContent = '';
    scorebug.classList.remove('stale-border');
    connectingIndicator.classList.remove('visible');
  } else if (staleIndicatorState === 'stale') {
    staleIndicator.className = 'stale';
    staleIndicator.textContent = '';
    scorebug.classList.add('stale-border');
    connectingIndicator.classList.remove('visible');
  } else if (staleIndicatorState === 'lost') {
    staleIndicator.className = 'lost';
    staleIndicator.textContent = 'Signal Lost';
    scorebug.classList.add('stale-border');
  }
}

/* Helpers */
async function fetchJSON(u) {
  const r = await fetch(u, { cache: 'no-store' });
  if (!r.ok) throw new Error(r.status);
  return r.json();
}

function cleanName(n) {
  return (n || "").replace(/\s*\(.*?\)\s*/g, " ").replace(/\s{2,}/g, " ").trim();
}

function abbreviateName(teamName) {
  if (!teamName) return "";
  const players = teamName.split("/").map(p => p.trim());
  const abbreviated = players.map(player => {
    const lower = player.toLowerCase();
    if (lower.includes("winner") || lower.includes("loser") ||
        lower.includes("team ") || lower.includes("seed ") ||
        lower.includes("match ") || lower.includes("this match")) {
      return player;
    }
    const parts = player.split(/\s+/);
    if (parts.length < 2) return player;
    return parts[parts.length - 1];
  });
  return abbreviated.join(" / ");
}

/* Replace "Match N" with "this match" when N is the current match */
function localizeMatchRef(text) {
  if (!text || !currentMatchNumber) return text;
  // Match patterns like "Winner of Match 5", "Loser of Match 12", "Match 5 Winner"
  var re = new RegExp('(Match\\s+)' + currentMatchNumber.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\b', 'gi');
  return text.replace(re, 'this match');
}

/* Set Pips */
function updatePips(pipsEl, setsWon, setsToWin) {
  if (!pipsEl) return;
  // Only rebuild if content actually changed
  var key = setsWon + '-' + setsToWin;
  if (pipsEl.dataset.lastPips === key) return;
  pipsEl.dataset.lastPips = key;
  var html = '';
  for (var i = 0; i < setsToWin; i++) {
    html += '<div class="set-pip ' + (i < setsWon ? 'bg-gold' : 'bg-gold-muted') + '"></div>';
  }
  pipsEl.innerHTML = html;
}

/* Bubble Animation Logic */
function showNextMatchBar(nextMatchText) {
  if (animationInProgress) return;
  clearTimeout(nextMatchTimer);
  clearTimeout(window.animSafetyTimer);
  animationInProgress = true;

  if (nextTeamsEl && nextMatchText) {
    const localized = localizeMatchRef(nextMatchText);
    const parts = localized.split(/\s+vs\.?\s+/i);
    if (parts.length >= 2) {
      nextTeamsEl.innerHTML = abbreviateName(parts[0]) + ' <span style="color: rgba(255,255,255,0.4); font-style: italic; margin: 0 4px; font-weight: 900;">vs</span> ' + abbreviateName(parts[1]);
    } else {
      nextTeamsEl.textContent = abbreviateName(localized);
    }
  }

  socialBar.classList.remove('visible');
  socialBar.classList.add('hidden-up');
  socialBar.style.fontSize = '';

  setTimeout(function() {
    nextBar.classList.remove('hidden-up');
    nextBar.classList.add('visible');
    fitBubbleToBoard(nextBar);
  }, 400);

  nextMatchTimer = setTimeout(function() {
    hideNextMatchBar();
  }, 17000);

  // Safety: reset animationInProgress after 20s as failsafe
  window.animSafetyTimer = setTimeout(function() {
    if (animationInProgress) {
      console.log('[Overlay] Animation safety timer — resetting stuck animation flag');
      animationInProgress = false;
    }
  }, 20000);
}

// Persistent next match bar for postmatch - stays until transition
function showNextMatchBarPersistent(nextMatchText) {
  // Clear any existing timer
  if (nextMatchTimer) {
    clearTimeout(nextMatchTimer);
    nextMatchTimer = null;
  }
  
  if (nextTeamsEl && nextMatchText) {
    const localized = localizeMatchRef(nextMatchText);
    const parts = localized.split(/\s+vs\.?\s+/i);
    if (parts.length >= 2) {
      nextTeamsEl.innerHTML = abbreviateName(parts[0]) + ' <span style="color: rgba(255,255,255,0.4); font-style: italic; margin: 0 4px; font-weight: 900;">vs</span> ' + abbreviateName(parts[1]);
    } else {
      nextTeamsEl.textContent = abbreviateName(localized);
    }
  }

  // Hide social bar
  socialBar.classList.remove('visible');
  socialBar.classList.add('hidden-up');

  // Show next bar (no auto-hide timer)
  setTimeout(function() {
    nextBar.classList.remove('hidden-up');
    nextBar.classList.add('visible');
    fitBubbleToBoard(nextBar);
  }, 400);
  
  // Mark as persistent mode
  window.nextBarPersistent = true;
  console.log('[Overlay] Showing persistent next match bar for postmatch');
}

function hideNextMatchBar() {
  nextBar.classList.remove('visible');
  nextBar.classList.add('hidden-up');
  nextBar.style.fontSize = '';
  window.nextBarPersistent = false;

  setTimeout(function() {
    if (socialBarEnabled) {
      socialBar.style.fontSize = '';
      socialBar.classList.remove('hidden-up');
      socialBar.classList.add('visible');
      fitBubbleToBoard(socialBar);
    }
    clearTimeout(window.animSafetyTimer);
    animationInProgress = false;
  }, 400);
}

/* Main score update */
function applyData(d) {
  if (!d) return;

  // Track current match number for "this match" substitution
  if (d.matchNumber) currentMatchNumber = String(d.matchNumber);

  const score1 = d.score1 || 0;
  const score2 = d.score2 || 0;
  const combinedScore = score1 + score2;
  const setsToWin = d.setsToWin || 2;

  // Team names
  if (t1El) t1El.textContent = abbreviateName(cleanName(d.team1)) || 'Team 1';
  if (t2El) t2El.textContent = abbreviateName(cleanName(d.team2)) || 'Team 2';

  // Team seeds (show on outside of team names)
  if (seed1El) seed1El.textContent = d.seed1 || '';
  if (seed2El) seed2El.textContent = d.seed2 || '';

  // Scores - with flip animation on change
  // Trigger flip animation if score changed
  if (sc1El && sc1El.textContent !== String(score1)) {
    sc1El.textContent = score1;
    sc1El.classList.remove('score-flip');
    requestAnimationFrame(function() { requestAnimationFrame(function() { sc1El.classList.add('score-flip'); }); });
  }
  if (sc2El && sc2El.textContent !== String(score2)) {
    sc2El.textContent = score2;
    sc2El.classList.remove('score-flip');
    requestAnimationFrame(function() { requestAnimationFrame(function() { sc2El.classList.add('score-flip'); }); });
  }

  // Set number (API returns 'set', not 'setNumber')
  if (setNumEl) setNumEl.textContent = d.set || 1;

  // Set pips
  updatePips(document.getElementById('pips1'), d.setsA || 0, setsToWin);
  updatePips(document.getElementById('pips2'), d.setsB || 0, setsToWin);

  // Serve indicator — skip entirely during celebration
  if (!celebrationActive) {
    const serveLeft = document.getElementById('serve-left');
    const serveRight = document.getElementById('serve-right');
    if (serveLeft && serveRight) {
      let isLeftServing = false;
      let isRightServing = false;

      // Detect serve based on who just scored (score increased)
      if (window.prevScore1 !== undefined && window.prevScore2 !== undefined) {
        if (d.score1 > window.prevScore1) {
          isLeftServing = true;
        } else if (d.score2 > window.prevScore2) {
          isRightServing = true;
        } else {
          // No score change - keep previous serve indicator
          isLeftServing = window.lastServe === 'left';
          isRightServing = window.lastServe === 'right';
        }
      } else if (combinedScore === 0) {
        // Match hasn't started - initialize scores for tracking
        window.prevScore1 = 0;
        window.prevScore2 = 0;
        isLeftServing = false;
        isRightServing = false;
      } else {
        // First time seeing scores > 0 with no prev - use API serve data if available
        window.prevScore1 = d.score1;
        window.prevScore2 = d.score2;
        const srv = (d.serve || "").toLowerCase();
        isLeftServing = srv.includes('home') || srv.includes('team1');
        isRightServing = srv.includes('away') || srv.includes('team2');
      }

      window.prevScore1 = d.score1;
      window.prevScore2 = d.score2;
      if (isLeftServing) window.lastServe = 'left';
      if (isRightServing) window.lastServe = 'right';

      serveLeft.style.opacity = isLeftServing ? '1' : '0';
      serveRight.style.opacity = isRightServing ? '1' : '0';
    }
  }

  // Next match bar trigger: every multiple of 7
  if (combinedScore > 0 && combinedScore % 7 === 0 && combinedScore !== lastTriggerScore) {
    lastTriggerScore = combinedScore;
    const nextMatch = d.nextMatch || '';
    if (nextMatch && !animationInProgress) {
      showNextMatchBar(nextMatch);
    }
  }

  // Match celebration: confetti + trophy for the winner
  if (isMatchFinished(d)) {
    const setsWon1 = d.setsA || 0;
    const setsWon2 = d.setsB || 0;
    const winner = setsWon1 > setsWon2 ? 'team1' : 'team2';
    showCelebration(winner);
    
    // Show persistent next match bar (stays until transition)
    const nextMatch = d.nextMatch || '';
    if (nextMatch && !window.nextBarPersistent) {
      showNextMatchBarPersistent(nextMatch);
    }
  } else if (celebrationActive) {
    clearCelebration();
  }

  // Always update traditional board (hidden elements cost nothing)
  applyTradData(d);
}

/* ===== MATCH CELEBRATION ===== */

function showCelebration(winner) {
  if (celebrationActive) return;
  celebrationActive = true;

  const confettiLeft = document.getElementById('confetti-left');
  const confettiRight = document.getElementById('confetti-right');
  const trophyLeft = document.getElementById('trophy-left');
  const trophyRight = document.getElementById('trophy-right');
  const team1Section = document.getElementById('team1-section');
  const team2Section = document.getElementById('team2-section');
  const sc1El = document.getElementById('sc1');
  const sc2El = document.getElementById('sc2');
  const setLabel = document.getElementById('set-label');
  const setNum = document.getElementById('set-num');
  const serveLeft = document.getElementById('serve-left');
  const serveRight = document.getElementById('serve-right');

  // Immediately hide serve indicators
  if (serveLeft) { serveLeft.style.opacity = '0'; }
  if (serveRight) { serveRight.style.opacity = '0'; }

  // Show FINAL label and hide set number
  if (setLabel) setLabel.textContent = 'FINAL';
  if (setNum) setNum.style.display = 'none';

  if (winner === 'team1') {
    if (confettiLeft) confettiLeft.classList.add('active');
    if (trophyLeft) trophyLeft.classList.add('visible');
    if (sc2El) sc2El.classList.add('loser-dim');
    if (team1Section) team1Section.classList.add('winner-glow');
  } else {
    if (confettiRight) confettiRight.classList.add('active');
    if (trophyRight) trophyRight.classList.add('visible');
    if (sc1El) sc1El.classList.add('loser-dim');
    if (team2Section) team2Section.classList.add('winner-glow');
  }

  console.log('[Overlay] Celebration triggered for', winner);
}

function clearCelebration() {
  if (!celebrationActive) return;
  celebrationActive = false;

  const confettiLeft = document.getElementById('confetti-left');
  const confettiRight = document.getElementById('confetti-right');
  const trophyLeft = document.getElementById('trophy-left');
  const trophyRight = document.getElementById('trophy-right');
  const team1Section = document.getElementById('team1-section');
  const team2Section = document.getElementById('team2-section');
  const sc1El = document.getElementById('sc1');
  const sc2El = document.getElementById('sc2');
  const setLabel = document.getElementById('set-label');
  const setNum = document.getElementById('set-num');

  if (confettiLeft) confettiLeft.classList.remove('active');
  if (confettiRight) confettiRight.classList.remove('active');
  if (trophyLeft) trophyLeft.classList.remove('visible');
  if (trophyRight) trophyRight.classList.remove('visible');
  if (team1Section) team1Section.classList.remove('winner-glow');
  if (team2Section) team2Section.classList.remove('winner-glow');
  if (sc1El) sc1El.classList.remove('loser-dim');
  if (sc2El) sc2El.classList.remove('loser-dim');
  if (setLabel) setLabel.textContent = 'SET';
  if (setNum) setNum.style.display = '';  // Restore set number visibility

  // Also clear traditional board celebration
  clearTradCelebration();
}

/* ===== MATCH CHANGE DETECTION ===== */

// Check if the match has changed (different team names)
function hasMatchChanged(d) {
  const newTeam1 = cleanName(d.team1 || '');
  const newTeam2 = cleanName(d.team2 || '');
  
  // Skip if we don't have valid team data yet
  if (!newTeam1 && !newTeam2) return false;
  
  // Skip if current match isn't tracked yet (first load)
  if (!currentMatchTeam1 && !currentMatchTeam2) return false;
  
  // Check if teams are different
  const team1Changed = newTeam1 !== currentMatchTeam1;
  const team2Changed = newTeam2 !== currentMatchTeam2;
  
  return team1Changed || team2Changed;
}

// Update the tracked current match
function updateCurrentMatch(team1, team2) {
  currentMatchTeam1 = cleanName(team1 || '');
  currentMatchTeam2 = cleanName(team2 || '');
}

// Animate match change: scoring → intermission, then either stay or go to scoring based on data
function animateMatchChange(newTeam1, newTeam2, newData) {
  if (transitionInProgress) {
    // Queue the match change for after current transition
    pendingMatchChange = { team1: newTeam1, team2: newTeam2, data: newData };
    return;
  }
  
  beginTransition();
  clearCelebration();
  animationInProgress = false; // Reset next-match animation state
  clearTimeout(nextMatchTimer);
  lastSetHistoryKey = ''; // Reset set history for new match
  lastEqualizedKey = ''; // Reset name equalization for new match
  console.log('[Overlay] Animating match change to:', abbreviateName(newTeam1), 'vs', abbreviateName(newTeam2));
  
  // Determine if new match should end in intermission or scoring
  const combinedScore = (newData.score1 || 0) + (newData.score2 || 0);
  const courtStatus = (newData.courtStatus || '').toLowerCase();
  const shouldEndInIntermission = combinedScore === 0 || courtStatus === 'waiting' || courtStatus === 'idle';
  
  // Pre-set the intermission team names (hidden)
  if (intTeam1) {
    intTeam1.textContent = abbreviateName(cleanName(newTeam1)) || 'TBD';
    intTeam1.style.transform = 'translateX(30px)';
    intTeam1.style.opacity = '0';
  }
  if (intTeam2) {
    intTeam2.textContent = abbreviateName(cleanName(newTeam2)) || 'TBD';
    intTeam2.style.transform = 'translateX(-30px)';
    intTeam2.style.opacity = '0';
  }
  if (intVs) intVs.style.opacity = '0';
  
  // Phase 1 (0-400ms): Retract ALL bubbles
  socialBar.classList.remove('visible');
  socialBar.classList.add('hidden-up');
  nextBar.classList.remove('visible');
  nextBar.classList.add('hidden-up');
  intStatusBar.classList.remove('visible');
  intStatusBar.classList.add('hidden-up');
  
  // Phase 2 (400-700ms): Slide scoring elements inward + fade
  setTimeout(function() {
    if (scoringContent) scoringContent.classList.add('slide-out');
  }, 400);
  
  // Phase 3 (700-1100ms): Swap to intermission content
  setTimeout(function() {
    if (scoringContent) {
      scoringContent.style.opacity = '0';
      scoringContent.style.pointerEvents = 'none';
    }
    
    // Set intermission width for symmetric layout
    setIntermissionWidth();
    
    if (intermissionContent) intermissionContent.classList.add('visible');
    
    // Show team names sliding out
    requestAnimationFrame(function() {
      if (intTeam1) {
        intTeam1.style.transform = 'translateX(0)';
        intTeam1.style.opacity = '1';
      }
      if (intTeam2) {
        intTeam2.style.transform = 'translateX(0)';
        intTeam2.style.opacity = '1';
      }
      if (intVs) intVs.style.opacity = '1';
    });
  }, 700);
  
  // Update current match tracking
  updateCurrentMatch(newTeam1, newTeam2);
  
  if (shouldEndInIntermission) {
    // END IN INTERMISSION MODE - show status bubble, stay in intermission
    setTimeout(function() {
      intStatusBar.classList.remove('hidden-up');
      intStatusBar.classList.add('visible');
      fitBubbleToBoard(intStatusBar);

      overlayState = 'intermission';
      endTransition();
      matchFinishedAt = null;
      postMatchTimer = null;
      
      console.log('[Overlay] Match change complete → intermission (0-0)');
      
      // Handle any queued match change
      if (pendingMatchChange) {
        const pending = pendingMatchChange;
        pendingMatchChange = null;
        setTimeout(function() {
          animateMatchChange(pending.team1, pending.team2, pending.data);
        }, 500);
      }
    }, 1600);
  } else {
    // END IN SCORING MODE - transition from intermission to scoring
    
    // Phase 4 (1700-2000ms): Hide intermission, prepare scoring
    setTimeout(function() {
      if (intTeam1) {
        intTeam1.style.transform = 'translateX(30px)';
        intTeam1.style.opacity = '0';
      }
      if (intTeam2) {
        intTeam2.style.transform = 'translateX(-30px)';
        intTeam2.style.opacity = '0';
      }
      if (intVs) intVs.style.opacity = '0';
    }, 1700);
    
    // Phase 5 (2000-2300ms): Show scoring with new data
    setTimeout(function() {
      if (intermissionContent) intermissionContent.classList.remove('visible');
      
      // Reset score tracking for serve indicator
      window.prevScore1 = undefined;
      window.prevScore2 = undefined;
      window.lastServe = undefined;
      lastTriggerScore = -1;
      
      // Apply new data
      applyData(newData);
      
      // Reset and show scoring content
      if (scoringContent) {
        scoringContent.classList.remove('slide-out');
        scoringContent.style.opacity = '1';
        scoringContent.style.pointerEvents = 'auto';
      }
      scorebug.style.width = SCORING_WIDTH;
    }, 2000);
    
    // Phase 6 (2300ms): Complete - show social bar
    setTimeout(function() {
      if (socialBarEnabled) {
        socialBar.classList.remove('hidden-up');
        socialBar.classList.add('visible');
        fitBubbleToBoard(socialBar);
      }

      overlayState = 'scoring';
      endTransition();
      matchFinishedAt = null;
      postMatchTimer = null;
      
      console.log('[Overlay] Match change complete → scoring');
      
      // Handle any queued match change
      if (pendingMatchChange) {
        const pending = pendingMatchChange;
        pendingMatchChange = null;
        setTimeout(function() {
          animateMatchChange(pending.team1, pending.team2, pending.data);
        }, 500);
      }
    }, 2300);
  }
}

/* ===== OVERLAY STATE TRANSITIONS ===== */

// Show intermission immediately (no animation, used on first load)
function showIntermissionImmediate(team1, team2) {
  // Hide scoring content
  if (scoringContent) {
    scoringContent.style.opacity = '0';
    scoringContent.style.pointerEvents = 'none';
  }

  // Update and show intermission content
  if (intTeam1) {
    intTeam1.textContent = abbreviateName(cleanName(team1)) || 'TBD';
    intTeam1.style.transform = 'translateX(0)';
    intTeam1.style.opacity = '1';
  }
  if (intTeam2) {
    intTeam2.textContent = abbreviateName(cleanName(team2)) || 'TBD';
    intTeam2.style.transform = 'translateX(0)';
    intTeam2.style.opacity = '1';
  }
  if (intVs) intVs.style.opacity = '1';
  if (intermissionContent) intermissionContent.classList.add('visible');

  // Hide social bar, show status bubble
  socialBar.classList.remove('visible');
  socialBar.classList.add('hidden-up');
  nextBar.classList.remove('visible');
  nextBar.classList.add('hidden-up');

  // Measure and set intermission width
  setIntermissionWidth();

  // Show status bubble
  setTimeout(function() {
    intStatusBar.classList.remove('hidden-up');
    intStatusBar.classList.add('visible');
    fitBubbleToBoard(intStatusBar);
  }, 300);

  overlayState = 'intermission';
  console.log('[Overlay] Showing intermission (immediate)');
}

function setIntermissionWidth() {
  if (!intermissionContent || !intTeam1 || !intTeam2) return;
  
  // Reset container widths to auto first so we can measure actual text widths
  if (intTeam1Container) intTeam1Container.style.width = 'auto';
  if (intTeam2Container) intTeam2Container.style.width = 'auto';
  
  // Temporarily make content static + auto-width to measure true sizes
  const origPos = intermissionContent.style.position;
  const origInset = intermissionContent.style.inset;
  const origWidth = intermissionContent.style.width;
  const origVis = intermissionContent.style.visibility;
  const origOpacity = intermissionContent.style.opacity;

  intermissionContent.style.position = 'static';
  intermissionContent.style.inset = 'auto';
  intermissionContent.style.width = 'auto';
  intermissionContent.style.visibility = 'hidden';
  intermissionContent.style.opacity = '0';

  // Force layout recalc and measure individual team name widths
  const team1Width = intTeam1.offsetWidth;
  const team2Width = intTeam2.offsetWidth;
  
  // Use the LARGER width for BOTH containers (symmetric layout)
  const maxTeamWidth = Math.max(team1Width, team2Width);
  
  // Set both containers to equal width
  if (intTeam1Container) intTeam1Container.style.width = maxTeamWidth + 'px';
  if (intTeam2Container) intTeam2Container.style.width = maxTeamWidth + 'px';
  
  // Re-measure total content width with equal containers
  const contentWidth = intermissionContent.offsetWidth;

  // Restore
  intermissionContent.style.position = origPos || '';
  intermissionContent.style.inset = origInset || '';
  intermissionContent.style.width = origWidth || '';
  intermissionContent.style.visibility = origVis || '';
  intermissionContent.style.opacity = origOpacity || '';

  const padding = 80; // left + right padding around content
  const minWidth = 300;
  const targetWidth = Math.max(contentWidth + padding, minWidth);
  scorebug.style.width = targetWidth + 'px';
}

// Transition from Scoring → Intermission (animated)
function transitionToIntermission(nextTeam1, nextTeam2) {
  if (transitionInProgress || overlayState === 'intermission') return;
  beginTransition();

  // Clear celebration before transitioning
  clearCelebration();

  // Pre-set the intermission team names (hidden)
  if (intTeam1) {
    intTeam1.textContent = abbreviateName(cleanName(nextTeam1)) || 'TBD';
    intTeam1.style.transform = 'translateX(30px)';
    intTeam1.style.opacity = '0';
  }
  if (intTeam2) {
    intTeam2.textContent = abbreviateName(cleanName(nextTeam2)) || 'TBD';
    intTeam2.style.transform = 'translateX(-30px)';
    intTeam2.style.opacity = '0';
  }
  if (intVs) intVs.style.opacity = '0';

  // Phase 1 (0-400ms): Retract bubbles
  socialBar.classList.remove('visible');
  socialBar.classList.add('hidden-up');
  nextBar.classList.remove('visible');
  nextBar.classList.add('hidden-up');

  // Phase 2 (400-900ms): Slide scoring elements inward + fade
  setTimeout(function() {
    if (scoringContent) scoringContent.classList.add('slide-out');
  }, 400);

  // Phase 3 (900-1100ms): Brief pause — empty bar
  setTimeout(function() {
    if (scoringContent) {
      scoringContent.style.opacity = '0';
      scoringContent.style.pointerEvents = 'none';
    }
  }, 900);

  // Phase 4 (1100-1600ms): Width adjusts to intermission size
  setTimeout(function() {
    setIntermissionWidth();
  }, 1100);

  // Phase 5 (1600-2100ms): Intermission content slides outward
  setTimeout(function() {
    if (intermissionContent) intermissionContent.classList.add('visible');

    // Trigger the slide-out animations on team names
    requestAnimationFrame(function() {
      if (intTeam1) {
        intTeam1.style.transform = 'translateX(0)';
        intTeam1.style.opacity = '1';
      }
      if (intTeam2) {
        intTeam2.style.transform = 'translateX(0)';
        intTeam2.style.opacity = '1';
      }
      if (intVs) intVs.style.opacity = '1';
    });
  }, 1600);

  // Phase 6 (2100-2500ms): Status bubble drops down
  setTimeout(function() {
    intStatusBar.classList.remove('hidden-up');
    intStatusBar.classList.add('visible');
    fitBubbleToBoard(intStatusBar);

    overlayState = 'intermission';
    endTransition();
    console.log('[Overlay] Transitioned to intermission');
  }, 2100);
}

// Transition from Intermission → Scoring (animated)
// Pass data parameter to pre-populate team names before reveal
function transitionToScoring(data) {
  if (transitionInProgress || overlayState === 'scoring') return;
  beginTransition();

  // IMMEDIATELY hide scoring content and reset scores to prevent flash
  if (scoringContent) {
    scoringContent.style.opacity = '0';
    scoringContent.style.pointerEvents = 'none';
  }
  const sc1El = document.getElementById('sc1');
  const sc2El = document.getElementById('sc2');
  if (sc1El) sc1El.textContent = '0';
  if (sc2El) sc2El.textContent = '0';

  // Phase 1 (0-400ms): Retract status bubble
  intStatusBar.classList.remove('visible');
  intStatusBar.classList.add('hidden-up');

  // Phase 2 (400-900ms): Intermission names slide inward + fade
  setTimeout(function() {
    if (intTeam1) {
      intTeam1.style.transform = 'translateX(30px)';
      intTeam1.style.opacity = '0';
    }
    if (intTeam2) {
      intTeam2.style.transform = 'translateX(-30px)';
      intTeam2.style.opacity = '0';
    }
    if (intVs) intVs.style.opacity = '0';
  }, 400);

  // Phase 3 (900-1400ms): Width expands back to scoring + PRE-APPLY DATA
  setTimeout(function() {
    if (intermissionContent) intermissionContent.classList.remove('visible');
    scorebug.style.width = SCORING_WIDTH;
    
    // Pre-apply data WHILE hidden to avoid placeholder flash
    if (data) {
      applyData(data);
    }
  }, 900);

  // Phase 4 (1400-1900ms): Scoring elements slide outward from center
  setTimeout(function() {
    // Reset scoring content
    if (scoringContent) {
      scoringContent.classList.remove('slide-out');
      scoringContent.style.opacity = '1';
      scoringContent.style.pointerEvents = 'auto';
    }
  }, 1400);

  // Phase 5 (1900-2300ms): Social bubble drops down
  setTimeout(function() {
    if (socialBarEnabled) {
      socialBar.classList.remove('hidden-up');
      socialBar.classList.add('visible');
      fitBubbleToBoard(socialBar);
    }

    overlayState = 'scoring';
    endTransition();
    matchFinishedAt = null;
    postMatchTimer = null;
    console.log('[Overlay] Transitioned to scoring');
  }, 1900);
}

/* ===== LAYOUT MANAGEMENT ===== */

function applyLayout(layout) {
  document.body.classList.remove('layout-center', 'layout-top-left', 'layout-bottom-left');
  document.body.classList.add('layout-' + layout);
  currentLayout = layout;
  // Update trad board height CSS variable for bubble positioning
  updateTradBoardHeight();
  console.log('[Overlay] Layout applied:', layout);
}

function updateTradBoardHeight() {
  if (tradBoard) {
    void tradBoard.offsetWidth; // force reflow
    var h = tradBoard.offsetHeight;
    var w = tradBoard.offsetWidth;
    if (h > 0) {
      document.documentElement.style.setProperty('--trad-board-height', h + 'px');
    }
    if (w > 0) {
      document.documentElement.style.setProperty('--trad-board-width', w + 'px');
    }
  }
}

function applyLayoutTransition(newLayout) {
  if (layoutTransitionInProgress || newLayout === currentLayout) return;
  layoutTransitionInProgress = true;

  var wrapper = document.getElementById('overlay-wrapper');

  // Phase 1: Fade out (350ms CSS transition)
  if (wrapper) wrapper.classList.add('layout-fading');

  // Phase 2: Swap layout classes while fully faded
  setTimeout(function() {
    applyLayout(newLayout);

    // Reset bubble bar animation state so transitions work in new layout
    clearTimeout(window.animSafetyTimer);
    animationInProgress = false;

    // Reset font-size on all bubble bars
    socialBar.style.fontSize = '';
    nextBar.style.fontSize = '';
    if (intStatusBar) intStatusBar.style.fontSize = '';

    // Re-equalize trad board name widths if switching to trad layout
    if (newLayout !== 'center') {
      equalizeTradNameWidths(true);
    }

    // Phase 3: Allow 1 frame for layout to render, then fade back in
    requestAnimationFrame(function() {
      // Update trad board dimensions for bubble positioning
      if (tradBoard && newLayout !== 'center') {
        var w = tradBoard.offsetWidth;
        var h = tradBoard.offsetHeight;
        if (w > 0) document.documentElement.style.setProperty('--trad-board-width', w + 'px');
        if (h > 0) document.documentElement.style.setProperty('--trad-board-height', h + 'px');
      }

      // Re-fit visible bubble bars for new layout
      if (newLayout !== 'center') {
        if (socialBar.classList.contains('visible')) fitBubbleToBoard(socialBar);
        if (nextBar.classList.contains('visible')) fitBubbleToBoard(nextBar);
        if (intStatusBar && intStatusBar.classList.contains('visible')) fitBubbleToBoard(intStatusBar);
      }

      // Fade back in
      requestAnimationFrame(function() {
        if (wrapper) wrapper.classList.remove('layout-fading');
        layoutTransitionInProgress = false;
        console.log('[Overlay] Layout transition complete:', newLayout);
      });
    });
  }, 380);
}

/* ===== TRADITIONAL SCOREBOARD ===== */

/* Shrink a bubble bar's font until its content fits the board width */
function fitBubbleToBoard(bar) {
  if (!bar || !tradBoard || currentLayout === 'center') return;
  var boardW = tradBoard.offsetWidth;
  if (boardW <= 0) return;
  var size = 11;
  bar.style.fontSize = size + 'px';
  // Force reflow so scrollWidth reflects the new font-size
  void bar.offsetWidth;
  while (bar.scrollWidth > boardW && size > 5) {
    size -= 0.5;
    bar.style.fontSize = size + 'px';
    void bar.offsetWidth; // force reflow each iteration
  }
}

function applyTradData(d) {
  if (!d) return;

  var score1 = d.score1 || 0;
  var score2 = d.score2 || 0;

  // Team names
  var name1 = abbreviateName(cleanName(d.team1)) || 'Team 1';
  var name2 = abbreviateName(cleanName(d.team2)) || 'Team 2';
  if (tradT1) tradT1.textContent = name1;
  if (tradT2) tradT2.textContent = name2;

  // Seeds
  if (tradSeed1) tradSeed1.textContent = d.seed1 ? '(' + d.seed1 + ')' : '';
  if (tradSeed2) tradSeed2.textContent = d.seed2 ? '(' + d.seed2 + ')' : '';

  // Equalize team name widths so score divider aligns between rows
  equalizeTradNameWidths();

  // Current score with flip animation
  if (tradSc1 && tradSc1.textContent !== String(score1)) {
    tradSc1.textContent = score1;
    tradSc1.classList.remove('score-flip');
    requestAnimationFrame(function() { requestAnimationFrame(function() { tradSc1.classList.add('score-flip'); }); });
  }
  if (tradSc2 && tradSc2.textContent !== String(score2)) {
    tradSc2.textContent = score2;
    tradSc2.classList.remove('score-flip');
    requestAnimationFrame(function() { requestAnimationFrame(function() { tradSc2.classList.add('score-flip'); }); });
  }

  // Serve indicators (reuse the same tracking as center layout)
  if (!tradCelebrationActive) {
    var isLeftServing = window.lastServe === 'left';
    var isRightServing = window.lastServe === 'right';
    if (tradServe1) tradServe1.classList.toggle('active', isLeftServing);
    if (tradServe2) tradServe2.classList.toggle('active', isRightServing);
  }

  // Set history columns
  rebuildSetColumns(d);

  // Handle intermission state for traditional board
  if (tradBoard) {
    var isIntermission = overlayState === 'intermission';
    tradBoard.classList.toggle('trad-intermission', isIntermission);
  }

  // Celebration for traditional board
  if (isMatchFinished(d)) {
    var setsWon1 = d.setsA || 0;
    var setsWon2 = d.setsB || 0;
    var winner = setsWon1 > setsWon2 ? 'team1' : 'team2';
    showTradCelebration(winner);
  } else if (tradCelebrationActive) {
    clearTradCelebration();
  }

  // Update board dimensions for bubble positioning
  updateTradBoardHeight();
}

var lastEqualizedKey = '';
function equalizeTradNameWidths(force) {
  if (!tradT1 || !tradT2) return;
  // Build a key from current text to avoid redundant work
  var key = tradT1.textContent + '|' + tradT2.textContent;
  if (key === lastEqualizedKey && !force) return;
  lastEqualizedKey = key;

  // Reset widths to auto so we can measure natural sizes
  tradT1.style.minWidth = '';
  tradT2.style.minWidth = '';

  // Force reflow and set matching widths immediately
  void tradT1.offsetWidth;
  var w1 = tradT1.offsetWidth;
  var w2 = tradT2.offsetWidth;
  var maxW = Math.max(w1, w2);
  tradT1.style.minWidth = maxW + 'px';
  tradT2.style.minWidth = maxW + 'px';
}

function rebuildSetColumns(d) {
  var setHistory = d.setHistory || [];
  // Build a key to avoid unnecessary DOM rebuilds
  var key = setHistory.join(',');
  if (key === lastSetHistoryKey) return;
  lastSetHistoryKey = key;

  var html1 = '';
  var html2 = '';

  for (var i = 0; i < setHistory.length; i++) {
    var parts = setHistory[i].split('-');
    if (parts.length < 2) continue;
    var s1 = parseInt(parts[0], 10);
    var s2 = parseInt(parts[1], 10);
    // Only show completed sets (not the current in-progress set)
    // The last entry in setHistory is the current set; previous ones are completed
    if (i < setHistory.length - 1) {
      var w1 = s1 > s2 ? 'set-winner' : 'set-loser';
      var w2 = s2 > s1 ? 'set-winner' : 'set-loser';
      html1 += '<span class="trad-set-cell ' + w1 + '">' + s1 + '</span>';
      html2 += '<span class="trad-set-cell ' + w2 + '">' + s2 + '</span>';
    }
  }

  if (tradSets1) tradSets1.innerHTML = html1;
  if (tradSets2) tradSets2.innerHTML = html2;

  // Board size changed — update CSS variable for bubble positioning
  updateTradBoardHeight();
}

function showTradCelebration(winner) {
  if (tradCelebrationActive) return;
  tradCelebrationActive = true;

  // Hide serve indicators
  if (tradServe1) tradServe1.classList.remove('active');
  if (tradServe2) tradServe2.classList.remove('active');

  if (winner === 'team1') {
    if (tradConfetti1) tradConfetti1.classList.add('active');
    if (tradTrophy1) tradTrophy1.classList.add('visible');
    if (tradRow1) tradRow1.classList.add('trad-winner-glow');
    if (tradRow2) tradRow2.classList.add('trad-loser-dim');
  } else {
    if (tradConfetti2) tradConfetti2.classList.add('active');
    if (tradTrophy2) tradTrophy2.classList.add('visible');
    if (tradRow2) tradRow2.classList.add('trad-winner-glow');
    if (tradRow1) tradRow1.classList.add('trad-loser-dim');
  }
  console.log('[Overlay] Trad celebration for', winner);
}

function clearTradCelebration() {
  if (!tradCelebrationActive) return;
  tradCelebrationActive = false;

  if (tradConfetti1) tradConfetti1.classList.remove('active');
  if (tradConfetti2) tradConfetti2.classList.remove('active');
  if (tradTrophy1) tradTrophy1.classList.remove('visible');
  if (tradTrophy2) tradTrophy2.classList.remove('visible');
  if (tradRow1) { tradRow1.classList.remove('trad-winner-glow'); tradRow1.classList.remove('trad-loser-dim'); }
  if (tradRow2) { tradRow2.classList.remove('trad-winner-glow'); tradRow2.classList.remove('trad-loser-dim'); }
}

// Check if match is finished based on sets won
function isMatchFinished(d) {
  const setsToWin = d.setsToWin || 2;
  const setsWon1 = d.setsA || 0;
  const setsWon2 = d.setsB || 0;
  return setsWon1 >= setsToWin || setsWon2 >= setsToWin;
}

// Determine overlay state based on data
function determineState(d) {
  const combinedScore = (d.score1 || 0) + (d.score2 || 0);
  const hasScoring = combinedScore > 0;
  const matchFinished = isMatchFinished(d);
  const courtStatus = (d.courtStatus || '').toLowerCase();
  
  // Check if match has already started (any sets won)
  const setsWon1 = d.setsA || 0;
  const setsWon2 = d.setsB || 0;
  const matchInProgress = setsWon1 > 0 || setsWon2 > 0;

  // If currently in intermission and scoring starts, switch to scoring
  if (overlayState === 'intermission' && hasScoring && !matchFinished) {
    return 'scoring';
  }

  // If match just finished, enter post-match state
  if (matchFinished && overlayState === 'scoring') {
    return 'postmatch';
  }

  // If in post-match and 3 min elapsed, go to intermission
  if (overlayState === 'postmatch') {
    if (matchFinishedAt && (Date.now() - matchFinishedAt >= POST_MATCH_HOLD_MS)) {
      return 'intermission';
    }
  }

  // If court is waiting/idle and score is 0-0 AND NO SETS WON YET, show intermission
  // (Don't transition if we're between sets in a multi-set match)
  if ((courtStatus === 'waiting' || courtStatus === 'idle') && combinedScore === 0 && !matchInProgress) {
    return 'intermission';
  }

  // On first load with no scoring AND no sets won, stay in intermission
  if (firstLoad && !hasScoring && !matchInProgress) {
    return 'intermission';
  }

  return overlayState;
}

/* Polling loop with state machine */
async function tick() {
  try {
    const d = await fetchJSON(SRC);
    if (!d) return;

    // Update dynamic hold duration from server settings
    POST_MATCH_HOLD_MS = d.holdDuration || 180000;

    // Track data freshness
    updateStaleState(JSON.stringify(d));

    // Layout change detection
    var newLayout = d.layout || 'center';
    if (newLayout !== currentLayout && !layoutTransitionInProgress) {
      applyLayoutTransition(newLayout);
    }

    // Social bar toggle
    var newSocialEnabled = d.showSocialBar !== false;
    if (newSocialEnabled !== socialBarEnabled) {
      socialBarEnabled = newSocialEnabled;
      if (!socialBarEnabled) {
        socialBar.classList.remove('visible');
        socialBar.classList.add('hidden-up');
      }
    }

    const newState = determineState(d);

    // First load — set up initial state based on ACTUAL DATA, not overlayState
    if (firstLoad) {
      firstLoad = false;
      // Initialize current match tracking
      updateCurrentMatch(d.team1 || '', d.team2 || '');

      // Apply initial layout
      applyLayout(d.layout || 'center');

      // Apply social bar toggle
      socialBarEnabled = d.showSocialBar !== false;
      
      const combinedScore = (d.score1 || 0) + (d.score2 || 0);
      const courtStatus = (d.courtStatus || '').toLowerCase();
      const matchFinished = isMatchFinished(d);
      
      // If there's an active score OR match is finished (postmatch), show scoring overlay
      if (combinedScore > 0 || matchFinished) {
        console.log('[Overlay] First load: Active scoring detected (score:', combinedScore, ')');
        overlayState = matchFinished ? 'postmatch' : 'scoring';
        
        // Initialize score tracking for serve indicator
        window.prevScore1 = 0;
        window.prevScore2 = 0;
        
        if (scoringContent) {
          scoringContent.style.opacity = '1';
          scoringContent.style.pointerEvents = 'auto';
        }
        scorebug.style.width = SCORING_WIDTH;
        if (socialBarEnabled) {
          socialBar.classList.remove('hidden-up');
          socialBar.classList.add('visible');
          fitBubbleToBoard(socialBar);
        }
        applyData(d);
        if (matchFinished) {
          matchFinishedAt = Date.now();
        }
        return;
      }
      
      // No active score - show intermission
      console.log('[Overlay] First load: No active score, showing intermission');
      const team1 = d.team1 || '';
      const team2 = d.team2 || '';
      showIntermissionImmediate(team1, team2);
      applyTradData(d);
      return;
    }

    // *** MATCH CHANGE DETECTION ***
    // Detect if match changed (manual skip via arrow keys, or auto-advance)
    if (hasMatchChanged(d) && !transitionInProgress) {
      const newTeam1 = d.team1 || '';
      const newTeam2 = d.team2 || '';
      console.log('[Overlay] Match change detected:', currentMatchTeam1, '->', newTeam1);
      
      // If we're in scoring/postmatch, animate the transition
      if (overlayState === 'scoring' || overlayState === 'postmatch') {
        animateMatchChange(newTeam1, newTeam2, d);
        return; // Let the animation handle everything
      } else if (overlayState === 'intermission') {
        // Animate intermission-to-intermission change with fade
        beginTransition();
        updateCurrentMatch(newTeam1, newTeam2);
        
        // Fade out the intermission content
        const intContent = document.getElementById('intermission-content');
        if (intContent) {
          intContent.style.transition = 'opacity 0.3s ease-out';
          intContent.style.opacity = '0';
          
          setTimeout(function() {
            // Update team names while faded out
            if (intTeam1) intTeam1.textContent = abbreviateName(cleanName(newTeam1)) || 'TBD';
            if (intTeam2) intTeam2.textContent = abbreviateName(cleanName(newTeam2)) || 'TBD';
            setIntermissionWidth();
            
            // Fade back in
            intContent.style.transition = 'opacity 0.3s ease-in';
            intContent.style.opacity = '1';
            
            setTimeout(function() {
              endTransition();
            }, 300);
          }, 300);
        } else {
          // Fallback if no content element
          if (intTeam1) intTeam1.textContent = abbreviateName(cleanName(newTeam1)) || 'TBD';
          if (intTeam2) intTeam2.textContent = abbreviateName(cleanName(newTeam2)) || 'TBD';
          endTransition();
        }
        return;
      }
    }

    // Handle state transitions
    if (newState === 'postmatch' && overlayState === 'scoring') {
      overlayState = 'postmatch';
      matchFinishedAt = Date.now();
      console.log('[Overlay] Match finished, holding for 3 minutes');
    }

    if (newState === 'intermission' && overlayState !== 'intermission' && !transitionInProgress) {
      const courtStatus = (d.courtStatus || '').toLowerCase();
      const team1 = d.team1 || '';
      const team2 = d.team2 || '';
      // After auto-advance, court is 'waiting' and team1/team2 already reflect the new match
      if (courtStatus === 'waiting' || courtStatus === 'idle') {
        transitionToIntermission(team1, team2);
      } else {
        // Coming from postmatch hold — use nextMatch to preview upcoming teams
        const nextMatch = d.nextMatch || '';
        const parts = nextMatch.split(/\s+vs\.?\s+/i);
        if (parts.length >= 2) {
          transitionToIntermission(parts[0], parts[1]);
        } else {
          transitionToIntermission(team1, team2);
        }
      }
    }

    if (newState === 'scoring' && overlayState === 'intermission' && !transitionInProgress) {
      // Update match tracking before transitioning to scoring
      updateCurrentMatch(d.team1 || '', d.team2 || '');
      transitionToScoring(d); // Pass data to pre-populate before reveal
    }

    // Apply data to scoring overlay if in scoring or postmatch state
    if ((overlayState === 'scoring' || overlayState === 'postmatch') && !transitionInProgress) {
      applyData(d);
    }

    // Always update traditional board (even during intermission - hidden elements cost nothing)
    if (overlayState === 'intermission' && !transitionInProgress) {
      applyTradData(d);
    }

  } catch (e) {
    console.log('[Overlay] Fetch error:', e);
    onFetchError();
  } finally {
    setTimeout(tick, POLL_MS);
  }
}

// Initialize: hide scoring content, start polling
if (scoringContent) {
  scoringContent.style.opacity = '0';
  scoringContent.style.pointerEvents = 'none';
}
socialBar.classList.remove('visible');
socialBar.classList.add('hidden-up');

tick();
</script>
</body>
</html>
"""#
}
