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
    
    // Score data cache for overlays
    private var latestScoreData: [Int: Data] = [:]
    
    // Hold mechanism for showing final scores
    private var holdQueue: [Int: (data: [String: Any], expires: Date)] = [:]
    
    private init() {}
    
    // MARK: - Lifecycle
    
    func start(with viewModel: AppViewModel, port: Int = NetworkConstants.webSocketPort) async {
        guard !isRunning else { 
            print("⚠️ Overlay server already running")
            return 
        }
        
        // Block further start calls immediately
        isRunning = true
        appViewModel = viewModel
        
        // Ensure old app is cleaned up
        if let oldApp = app { 
            print("🧹 Cleaning up existing server instance...")
            do {
                try await oldApp.asyncShutdown()
            } catch {
                print("⚠️ Error shutting down old app: \(error)")
            }
            app = nil
        }
        
        // Initialize with explicit arguments to ignore Xcode/OS flags that crash Vapor
        let env = Environment(name: "development", arguments: ["vapor"])
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
                        print("✅ Overlay server running at http://localhost:\(port)/overlay/court/X")
                    }
                } catch {
                    print("❌ Failed to start overlay server: \(error)")
                    await MainActor.run {
                        WebSocketHub.shared.isRunning = false
                        WebSocketHub.shared.app = nil
                    }
                }
            }
        } catch {
            print("❌ Failed to initialize Vapor Application: \(error)")
            self.isRunning = false
        }
    }
    
    func stop() {
        Task {
            print("🛑 Stopping overlay server...")
            do {
                try await app?.asyncShutdown()
            } catch {
                print("⚠️ Error shutting down app: \(error)")
            }
            app = nil
            isRunning = false
            print("🛑 Overlay server stopped")
        }
    }
    
    // MARK: - Data Update
    
    func updateScore(courtId: Int, data: Data) {
        latestScoreData[courtId] = data
    }
    
    // MARK: - Routes
    
    private func installRoutes(_ app: Application) {
        // Health check
        app.get("health") { _ in "ok" }
        
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
        
        // Redirect without trailing slash
        app.get("overlay", "court", ":id", "") { req async throws -> Response in
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
                
                // Build response
                // Current game score comes from setHistory.last (the in-progress or last completed set)
                // snapshot.team1Score is actually SETS WON in this data model
                let currentGame = snapshot?.setHistory.last
                let gameScore1 = currentGame?.team1Score ?? currentMatch?.team1_score ?? 0
                let gameScore2 = currentGame?.team2Score ?? currentMatch?.team2_score ?? 0
                
                // DEBUG: Log score values
                print("[Overlay Debug] snapshot exists: \(snapshot != nil), setHistory count: \(snapshot?.setHistory.count ?? -1)")
                print("[Overlay Debug] currentGame: \(currentGame?.team1Score ?? -1) - \(currentGame?.team2Score ?? -1)")
                print("[Overlay Debug] gameScore1: \(gameScore1), gameScore2: \(gameScore2)")
                print("[Overlay Debug] currentMatch?.team1_score: \(currentMatch?.team1_score ?? -1)")
                
                let data: [String: Any] = [
                    "team1": team1,
                    "team2": team2,
                    "score1": gameScore1,  // Current game score (from setHistory.last)
                    "score2": gameScore2,  // Current game score (from setHistory.last)
                    "setsWon1": snapshot?.team1Score ?? 0,  // Sets won by team 1 (this IS sets won in the model)
                    "setsWon2": snapshot?.team2Score ?? 0,  // Sets won by team 2 (this IS sets won in the model)
                    "set": snapshot?.setNumber ?? 1,
                    "status": snapshot?.status ?? "Pre-Match",
                    "courtStatus": court.status.rawValue,  // "idle", "waiting", "live", "postmatch"
                    "setsA": snapshot?.totalSetsWon.team1 ?? 0,
                    "setsB": snapshot?.totalSetsWon.team2 ?? 0,
                    "serve": snapshot?.serve ?? "none",
                    "setHistory": snapshot?.setHistory.map { $0.displayString } ?? [],
                    
                    // Fields added for seed support
                    "seed1": seed1,
                    "seed2": seed2,
                    
                    // Match format (for determining when match ends)
                    "setsToWin": currentMatch?.setsToWin ?? 2,
                    "pointsPerSet": currentMatch?.pointsPerSet ?? 21,
                    "pointCap": currentMatch?.pointCap as Any,
                    
                    // Up Next - empty string if no actual next match
                    "nextMatch": court.nextMatch?.displayName ?? ""
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
            
            // Fetch names from API (off MainActor)
            do {
                let (responseData, _) = try await URLSession.shared.data(from: data.url)
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
    
    private func generateOverlayHTML(courtId: String) -> String {
        var html = Self.bvmOverlayHTML
        // Inject court-specific endpoints (new Tailwind overlay format)
        html = html.replacingOccurrences(
            of: #"const SRC = "/score.json";"#,
            with: #"const SRC = "/overlay/court/\#(courtId)/score.json";"#
        )
        html = html.replacingOccurrences(
            of: #"const NEXT_SRC = "/next.json";"#,
            with: #"const NEXT_SRC = "/overlay/court/\#(courtId)/next.json";"#
        )
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
<script src="https://cdn.tailwindcss.com?plugins=forms,container-queries"></script>
<link href="https://fonts.googleapis.com/css2?family=Roboto+Condensed:ital,wght@0,100..900;1,100..900&display=swap" rel="stylesheet"/>
<link href="https://fonts.googleapis.com/css2?family=Material+Symbols+Outlined:wght,FILL@100..700,0..1&display=swap" rel="stylesheet"/>
<link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css" rel="stylesheet"/>
<script>
tailwind.config = {
  darkMode: "class",
  theme: {
    extend: {
      colors: {
        "carbon": "#121212",
        "gold": "#D4AF37",
        "gold-bright": "#F9E29B",
        "gold-muted": "rgba(212, 175, 55, 0.25)",
      },
      fontFamily: {
        "display": ["Roboto Condensed", "sans-serif"]
      }
    },
  },
}
</script>
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
  line-height: 1;
  padding: 0.25em 0.35em;
}
.bubble-bar {
  background: rgba(0, 0, 0, 0.8);
  backdrop-filter: blur(8px);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-top: none;
  border-radius: 0 0 0.5rem 0.5rem;
  overflow: hidden;
}
.insta-gradient {
  background: radial-gradient(circle at 30% 107%, #fdf497 0%, #fdf497 5%, #fd5949 45%, #d6249f 60%, #285AEB 90%);
  -webkit-background-clip: text;
  background-clip: text;
  -webkit-text-fill-color: transparent;
}
.bg-gold { background-color: #D4AF37; }
.bg-gold-muted { background-color: rgba(212, 175, 55, 0.25); }

/* Confetti celebration */
@keyframes confetti-fall {
  0% { transform: translateY(-5px) rotate(0deg); opacity: 0; }
  10% { opacity: 0.85; }
  100% { transform: translateY(80px) rotate(720deg); opacity: 0; }
}
.confetti-container {
  position: absolute;
  inset: 0;
  pointer-events: none;
  z-index: 10;
  overflow: hidden;
  opacity: 0;
  transition: opacity 0.6s ease;
}
.confetti-container.active { opacity: 1; }
.confetti-piece {
  position: absolute;
  width: 4px;
  height: 8px;
  opacity: 0;
  top: -10%;
  border-radius: 1px;
}
.confetti-container.active .confetti-piece {
  animation: confetti-fall 3s linear infinite;
}
.cf-1 { left: 10%; background: #D4AF37; animation-delay: 0s; }
.cf-2 { left: 22%; background: #FFD700; animation-delay: 0.5s; }
.cf-3 { left: 35%; background: #FFFFFF; animation-delay: 1.2s; }
.cf-4 { left: 48%; background: #D4AF37; animation-delay: 0.2s; }
.cf-5 { left: 60%; background: #FFD700; animation-delay: 1.8s; }
.cf-6 { left: 72%; background: #F9E29B; animation-delay: 0.9s; }
.cf-7 { left: 15%; background: #D4AF37; animation-delay: 2.1s; }
.cf-8 { left: 42%; background: #FFFFFF; animation-delay: 0.7s; }
.cf-9 { left: 80%; background: #FFD700; animation-delay: 1.5s; }
.cf-10 { left: 90%; background: #D4AF37; animation-delay: 2.5s; }

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
  background-color: transparent;
  margin: 0;
  padding: 0;
  font-family: "Roboto Condensed", sans-serif;
  color: white;
  overflow: hidden;
}
.serving-pulse {
  animation: pulse-gold 2s cubic-bezier(0.4, 0, 0.6, 1) infinite;
}
@keyframes pulse-gold {
  0%, 100% { opacity: 1; transform: scale(1.1); }
  50% { opacity: 0.5; transform: scale(0.9); }
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
}
.bubble-bar.hidden-up {
  transform: translateY(-120%);
  opacity: 0;
  pointer-events: none;
}
.bubble-bar.visible {
  transform: translateY(0);
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
@keyframes status-pulse {
  0%, 100% {
    box-shadow: 0 0 5px rgba(212, 175, 55, 0.3), inset 0 0 5px rgba(212, 175, 55, 0.1);
    border-color: rgba(212, 175, 55, 0.4);
  }
  50% {
    box-shadow: 0 0 20px rgba(212, 175, 55, 0.6), inset 0 0 10px rgba(212, 175, 55, 0.2);
    border-color: rgba(212, 175, 55, 0.9);
  }
}
</style>
</head>
<body style="display: flex; flex-direction: column; align-items: center; padding-top: 2rem;">

<div style="display: flex; flex-direction: column; align-items: center; width: 100%; max-width: 900px; padding: 0 1rem;">
  <!-- Main Scoreboard -->
  <div id="scorebug" class="carbon-bar" style="width: 100%; height: 4rem; border-radius: 0.375rem; display: flex; align-items: center; box-shadow: 0 8px 30px rgb(0,0,0,0.8); position: relative; overflow: hidden; z-index: 20;">

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
        </div>
        <div style="display: flex; align-items: center; gap: 1rem; position: relative; z-index: 20;">
          <span id="trophy-left" class="material-symbols-outlined trophy-icon">emoji_events</span>
          <div style="display: flex; flex-direction: column; justify-content: center;">
            <span id="t1" style="font-size: 1.125rem; font-weight: 800; text-transform: uppercase; letter-spacing: -0.025em; color: rgba(255,255,255,0.95); line-height: 1; margin-bottom: 0.375rem; font-style: italic;">Team 1</span>
            <div id="pips1" style="display: flex; gap: 0.375rem;">
              <div class="set-pip bg-gold-muted"></div>
              <div class="set-pip bg-gold-muted"></div>
            </div>
          </div>
          <span id="serve-left" class="material-symbols-outlined" style="font-size: 1.5rem; color: #D4AF37; opacity: 0;">sports_volleyball</span>
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
        </div>
        <div class="score-container" style="position: relative; z-index: 20;">
          <span id="sc2" class="score-text">0</span>
        </div>
        <div style="display: flex; align-items: center; gap: 1rem; text-align: right; position: relative; z-index: 20;">
          <span id="serve-right" class="material-symbols-outlined" style="font-size: 1.5rem; color: #D4AF37; opacity: 0;">sports_volleyball</span>
          <div style="display: flex; flex-direction: column; align-items: flex-end; justify-content: center;">
            <span id="t2" style="font-size: 1.125rem; font-weight: 800; text-transform: uppercase; letter-spacing: -0.025em; color: rgba(255,255,255,0.95); line-height: 1; margin-bottom: 0.375rem; font-style: italic;">Team 2</span>
            <div id="pips2" style="display: flex; gap: 0.375rem;">
              <div class="set-pip bg-gold-muted"></div>
              <div class="set-pip bg-gold-muted"></div>
            </div>
          </div>
          <span id="trophy-right" class="material-symbols-outlined trophy-icon">emoji_events</span>
        </div>
      </div>
    </div>

    <!-- Intermission Content Layer (overlaid, hidden by default) -->
    <div id="intermission-content">
      <div style="display: flex; align-items: center; flex-shrink: 0;">
        <span id="int-team1" style="font-size: 1.25rem; font-weight: 900; text-transform: uppercase; letter-spacing: -0.025em; color: white; font-style: italic; white-space: nowrap; transform: translateX(30px); transition: transform 0.5s cubic-bezier(0.4,0,0.2,1), opacity 0.5s ease; opacity: 0;">Team 1</span>
      </div>
      <div id="int-vs" style="display: flex; align-items: center; flex-shrink: 0; margin: 0 1rem; opacity: 0; transition: opacity 0.5s ease;">
        <div style="width: 1px; height: 1.5rem; background: rgba(255,255,255,0.2);"></div>
        <span style="font-size: 1.125rem; font-weight: 900; font-style: italic; letter-spacing: 0.15em; padding: 0 1rem; background: linear-gradient(180deg, #F9E29B 0%, #D4AF37 100%); -webkit-background-clip: text; -webkit-text-fill-color: transparent;">VS</span>
        <div style="width: 1px; height: 1.5rem; background: rgba(255,255,255,0.2);"></div>
      </div>
      <div style="display: flex; align-items: center; flex-shrink: 0;">
        <span id="int-team2" style="font-size: 1.25rem; font-weight: 900; text-transform: uppercase; letter-spacing: -0.025em; color: white; font-style: italic; white-space: nowrap; transform: translateX(-30px); transition: transform 0.5s cubic-bezier(0.4,0,0.2,1), opacity 0.5s ease; opacity: 0;">Team 2</span>
      </div>
    </div>

    <!-- Bottom Accent Line -->
    <div style="position: absolute; bottom: 0; left: 0; right: 0; height: 2px; background: linear-gradient(90deg, transparent, rgba(212,175,55,0.5), transparent); z-index: 30;"></div>
  </div>
  
  <!-- Bubble Container (holds social bar OR next match bar) -->
  <div class="bubble-container">
    <!-- Social Media Bar (default visible) -->
    <div id="social-bar" class="bubble-bar visible" style="padding: 0.375rem 1.25rem; display: flex; align-items: center; gap: 0.75rem; box-shadow: 0 4px 12px rgba(0,0,0,0.5);">
      <i class="fa-brands fa-facebook" style="color: #1877F2; font-size: 0.875rem;"></i>
      <i class="fa-brands fa-instagram insta-gradient" style="font-size: 0.875rem;"></i>
      <i class="fa-brands fa-youtube" style="color: #FF0000; font-size: 0.875rem;"></i>
      <span style="font-size: 0.75rem; font-weight: 600; letter-spacing: 0.025em; color: rgba(255,255,255,0.9);">@BeachVolleyballMedia</span>
    </div>
    
    <!-- Next Match Bar (hidden by default) -->
    <div id="next-bar" class="bubble-bar hidden-up" style="padding: 0.375rem 1.25rem; display: flex; align-items: center; gap: 0.5rem; box-shadow: 0 4px 12px rgba(0,0,0,0.5); white-space: nowrap; flex-wrap: nowrap;">
      <span style="font-size: 10px; font-weight: 900; color: #D4AF37; text-transform: uppercase; letter-spacing: 0.05em; flex-shrink: 0;">Next</span>
      <span style="color: rgba(255,255,255,0.3); flex-shrink: 0;">|</span>
      <span id="next-teams" style="font-size: 0.75rem; font-weight: 600; letter-spacing: 0.025em; color: rgba(255,255,255,0.95); text-transform: uppercase; white-space: nowrap;">Loading...</span>
    </div>

    <!-- Intermission Status Bubble (hidden by default) -->
    <div id="int-status-bar" class="status-bubble bubble-bar hidden-up" style="padding: 0.25rem 1.25rem; box-shadow: 0 4px 12px rgba(0,0,0,0.5);">
      <span style="font-size: 9px; font-weight: 900; letter-spacing: 0.2em; text-transform: uppercase; background: linear-gradient(180deg, #F9E29B 0%, #D4AF37 100%); -webkit-background-clip: text; -webkit-text-fill-color: transparent;">Match Starting Soon</span>
    </div>
  </div>
</div>

<script>
const SRC = "/score.json";
const NEXT_SRC = "/next.json";
const POLL_MS = 1000;
const POST_MATCH_HOLD_MS = 180000; // 3 minutes hold after match ends
const SCORING_WIDTH = '100%';

// Overlay State Machine: 'scoring' | 'postmatch' | 'intermission'
let overlayState = 'intermission'; // Start in intermission until scoring data arrives
let postMatchTimer = null;
let matchFinishedAt = null;
let lastMatchId = null;
let firstLoad = true;

// Animation state
let lastTriggerScore = -1;
let animationInProgress = false;
let nextMatchTimer = null;
let transitionInProgress = false;
let celebrationActive = false;

// DOM refs
const scorebug = document.getElementById('scorebug');
const scoringContent = document.getElementById('scoring-content');
const intermissionContent = document.getElementById('intermission-content');
const socialBar = document.getElementById('social-bar');
const nextBar = document.getElementById('next-bar');
const nextTeamsEl = document.getElementById('next-teams');
const intTeam1 = document.getElementById('int-team1');
const intTeam2 = document.getElementById('int-team2');
const intVs = document.getElementById('int-vs');
const intStatusBar = document.getElementById('int-status-bar');

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
        lower.includes("match ")) {
      return player;
    }
    const parts = player.split(/\s+/);
    if (parts.length < 2) return player;
    return parts[parts.length - 1];
  });
  return abbreviated.join(" / ");
}

/* Set Pips */
function updatePips(pipsEl, setsWon, setsToWin) {
  if (!pipsEl) return;
  let html = '';
  for (let i = 0; i < setsToWin; i++) {
    const filled = i < setsWon;
    html += '<div class="set-pip ' + (filled ? 'bg-gold' : 'bg-gold-muted') + '"></div>';
  }
  pipsEl.innerHTML = html;
}

/* Bubble Animation Logic */
function showNextMatchBar(nextMatchText) {
  if (animationInProgress) return;
  animationInProgress = true;

  if (nextTeamsEl && nextMatchText) {
    const parts = nextMatchText.split(/\s+vs\.?\s+/i);
    if (parts.length >= 2) {
      nextTeamsEl.innerHTML = abbreviateName(parts[0]) + ' <span style="color: rgba(255,255,255,0.4); font-style: italic; margin: 0 4px; font-weight: 900;">vs</span> ' + abbreviateName(parts[1]);
    } else {
      nextTeamsEl.textContent = abbreviateName(nextMatchText);
    }
  }

  socialBar.classList.remove('visible');
  socialBar.classList.add('hidden-up');

  setTimeout(function() {
    nextBar.classList.remove('hidden-up');
    nextBar.classList.add('visible');
  }, 400);

  nextMatchTimer = setTimeout(function() {
    hideNextMatchBar();
  }, 17000);
}

function hideNextMatchBar() {
  nextBar.classList.remove('visible');
  nextBar.classList.add('hidden-up');

  setTimeout(function() {
    socialBar.classList.remove('hidden-up');
    socialBar.classList.add('visible');
    animationInProgress = false;
  }, 400);
}

/* Main score update */
function applyData(d) {
  if (!d) return;

  const score1 = d.score1 || 0;
  const score2 = d.score2 || 0;
  const combinedScore = score1 + score2;
  const setsToWin = d.setsToWin || 2;

  // Team names
  const t1El = document.getElementById('t1');
  const t2El = document.getElementById('t2');
  if (t1El) t1El.textContent = abbreviateName(cleanName(d.team1)) || 'Team 1';
  if (t2El) t2El.textContent = abbreviateName(cleanName(d.team2)) || 'Team 2';

  // Scores
  const sc1El = document.getElementById('sc1');
  const sc2El = document.getElementById('sc2');
  if (sc1El) sc1El.textContent = score1;
  if (sc2El) sc2El.textContent = score2;

  // Set number
  const setNumEl = document.getElementById('set-num');
  if (setNumEl) setNumEl.textContent = d.setNumber || 1;

  // Set pips
  updatePips(document.getElementById('pips1'), d.setsWon1 || 0, setsToWin);
  updatePips(document.getElementById('pips2'), d.setsWon2 || 0, setsToWin);

  // Serve indicator — skip entirely during celebration
  if (!celebrationActive) {
    const serveLeft = document.getElementById('serve-left');
    const serveRight = document.getElementById('serve-right');
    if (serveLeft && serveRight) {
      let isLeftServing = false;
      let isRightServing = false;

      if (window.prevScore1 !== undefined && window.prevScore2 !== undefined) {
        if (d.score1 > window.prevScore1) {
          isLeftServing = true;
        } else if (d.score2 > window.prevScore2) {
          isRightServing = true;
        } else {
          isLeftServing = window.lastServe === 'left';
          isRightServing = window.lastServe === 'right';
        }
      } else if (combinedScore === 0) {
        isLeftServing = false;
        isRightServing = false;
      } else {
        const srv = (d.serve || "").toLowerCase();
        isLeftServing = srv.includes('home') || srv.includes('team1');
        isRightServing = srv.includes('away') || srv.includes('team2');
      }

      window.prevScore1 = d.score1;
      window.prevScore2 = d.score2;
      if (isLeftServing) window.lastServe = 'left';
      if (isRightServing) window.lastServe = 'right';

      serveLeft.style.opacity = isLeftServing ? '1' : '0';
      serveLeft.classList.toggle('serving-pulse', isLeftServing);
      serveRight.style.opacity = isRightServing ? '1' : '0';
      serveRight.classList.toggle('serving-pulse', isRightServing);
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
    const setsWon1 = d.setsA || d.setsWon1 || 0;
    const setsWon2 = d.setsB || d.setsWon2 || 0;
    const winner = setsWon1 > setsWon2 ? 'team1' : 'team2';
    showCelebration(winner);
  } else if (celebrationActive) {
    clearCelebration();
  }
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
  const serveLeft = document.getElementById('serve-left');
  const serveRight = document.getElementById('serve-right');

  // Immediately hide serve indicators
  if (serveLeft) { serveLeft.style.opacity = '0'; serveLeft.classList.remove('serving-pulse'); }
  if (serveRight) { serveRight.style.opacity = '0'; serveRight.classList.remove('serving-pulse'); }

  // Show FINAL label
  if (setLabel) setLabel.textContent = 'FINAL';

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

  if (confettiLeft) confettiLeft.classList.remove('active');
  if (confettiRight) confettiRight.classList.remove('active');
  if (trophyLeft) trophyLeft.classList.remove('visible');
  if (trophyRight) trophyRight.classList.remove('visible');
  if (team1Section) team1Section.classList.remove('winner-glow');
  if (team2Section) team2Section.classList.remove('winner-glow');
  if (sc1El) sc1El.classList.remove('loser-dim');
  if (sc2El) sc2El.classList.remove('loser-dim');
  if (setLabel) setLabel.textContent = 'SET';
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
  }, 300);

  overlayState = 'intermission';
  console.log('[Overlay] Showing intermission (immediate)');
}

function setIntermissionWidth() {
  // Temporarily make intermission content visible to measure
  if (intermissionContent) {
    intermissionContent.style.visibility = 'visible';
    intermissionContent.style.position = 'absolute';
    // Measure the actual content width
    const contentWidth = intermissionContent.scrollWidth + 80; // Add padding
    const minWidth = 400;
    const targetWidth = Math.max(contentWidth, minWidth);
    scorebug.style.width = targetWidth + 'px';
  }
}

// Transition from Scoring → Intermission (animated)
function transitionToIntermission(nextTeam1, nextTeam2) {
  if (transitionInProgress || overlayState === 'intermission') return;
  transitionInProgress = true;

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

    overlayState = 'intermission';
    transitionInProgress = false;
    console.log('[Overlay] Transitioned to intermission');
  }, 2100);
}

// Transition from Intermission → Scoring (animated)
function transitionToScoring() {
  if (transitionInProgress || overlayState === 'scoring') return;
  transitionInProgress = true;

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

  // Phase 3 (900-1400ms): Width expands back to scoring
  setTimeout(function() {
    if (intermissionContent) intermissionContent.classList.remove('visible');
    scorebug.style.width = SCORING_WIDTH;
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
    socialBar.classList.remove('hidden-up');
    socialBar.classList.add('visible');

    overlayState = 'scoring';
    transitionInProgress = false;
    matchFinishedAt = null;
    postMatchTimer = null;
    console.log('[Overlay] Transitioned to scoring');
  }, 1900);
}

// Check if match is finished based on sets won
function isMatchFinished(d) {
  const setsToWin = d.setsToWin || 2;
  const setsWon1 = d.setsA || d.setsWon1 || 0;
  const setsWon2 = d.setsB || d.setsWon2 || 0;
  return setsWon1 >= setsToWin || setsWon2 >= setsToWin;
}

// Determine overlay state based on data
function determineState(d) {
  const combinedScore = (d.score1 || 0) + (d.score2 || 0);
  const hasScoring = combinedScore > 0;
  const matchFinished = isMatchFinished(d);
  const courtStatus = (d.courtStatus || '').toLowerCase();

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

  // If court is waiting/idle and score is 0-0, show intermission
  if ((courtStatus === 'waiting' || courtStatus === 'idle') && combinedScore === 0) {
    return 'intermission';
  }

  // On first load with no scoring, stay in intermission
  if (firstLoad && !hasScoring) {
    return 'intermission';
  }

  return overlayState;
}

/* Polling loop with state machine */
async function tick() {
  try {
    const d = await fetchJSON(SRC);
    if (!d) return;

    const newState = determineState(d);

    // First load — set up initial state without animation
    if (firstLoad) {
      firstLoad = false;
      if (newState === 'intermission' || newState === 'scoring' && ((d.score1 || 0) + (d.score2 || 0)) === 0) {
        // Show intermission immediately
        const team1 = d.team1 || '';
        const team2 = d.team2 || '';
        showIntermissionImmediate(team1, team2);
        return;
      } else if (newState === 'scoring' || newState === 'postmatch') {
        // Show scoring immediately (skip animation)
        overlayState = 'scoring';
        if (scoringContent) {
          scoringContent.style.opacity = '1';
          scoringContent.style.pointerEvents = 'auto';
        }
        scorebug.style.width = SCORING_WIDTH;
        socialBar.classList.remove('hidden-up');
        socialBar.classList.add('visible');
        applyData(d);
        if (newState === 'postmatch') {
          overlayState = 'postmatch';
          matchFinishedAt = Date.now();
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
      const nextMatch = d.nextMatch || '';
      const team1 = d.team1 || '';
      const team2 = d.team2 || '';
      const parts = nextMatch.split(/\s+vs\.?\s+/i);
      if (parts.length >= 2) {
        transitionToIntermission(parts[0], parts[1]);
      } else if (nextMatch) {
        transitionToIntermission(nextMatch, 'TBD');
      } else {
        // No next match info — use current team names
        transitionToIntermission(team1, team2);
      }
    }

    if (newState === 'scoring' && overlayState === 'intermission' && !transitionInProgress) {
      transitionToScoring();
    }

    // Apply data to scoring overlay if in scoring or postmatch state
    if ((overlayState === 'scoring' || overlayState === 'postmatch') && !transitionInProgress) {
      applyData(d);
    }

  } catch (e) {
    console.log('[Overlay] Fetch error:', e);
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

