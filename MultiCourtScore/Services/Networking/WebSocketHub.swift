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
                        "nextMatch": "TBD"
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
                // Calculate current game score (from current/last set)
                let currentGame = snapshot?.setHistory.last
                let gameScore1 = currentGame?.team1Score ?? 0
                let gameScore2 = currentGame?.team2Score ?? 0
                
                let data: [String: Any] = [
                    "team1": team1,
                    "team2": team2,
                    "score1": gameScore1,  // Current game score (what shows large)
                    "score2": gameScore2,  // Current game score (what shows large)
                    "setsWon1": snapshot?.team1Score ?? 0,  // Sets won by team 1
                    "setsWon2": snapshot?.team2Score ?? 0,  // Sets won by team 2
                    "set": snapshot?.setNumber ?? 1,
                    "status": snapshot?.status ?? "Pre-Match",
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
                    
                    // Up Next
                    "nextMatch": court.nextMatch?.displayName ?? "TBD"
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
        // Inject court-specific endpoints
        html = html.replacingOccurrences(
            of: #"const SRC = "/score.json"; const NEXT_SRC = "/next.json"; const LABEL_SRC = "/label.json";"#,
            with: #"const SRC = "/overlay/court/\#(courtId)/score.json"; const NEXT_SRC = "/overlay/court/\#(courtId)/next.json"; const LABEL_SRC = "/overlay/court/\#(courtId)/label.json";"#
        )
        return html
    }
    
    // MARK: - Embedded HTML (Restored from V1)
    private static let bvmOverlayHTML: String = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>BVM Scorebug Overlay</title>
<style>
:root{
  --gold1:#ffd700; --gold2:#ffb300; --goldGlow:rgba(255,215,0,.25);
  --bgTop:#141414; --bgBot:#1c1c1c; --text:#fff; --muted:rgba(255,255,255,.85);
  --score-size:38px; --sets-size:14px; --maxw:900px; --bugw:900px;
}
html,body{margin:0;background:transparent;color:var(--text);font-family:system-ui,-apple-system,Segoe UI,Roboto,Helvetica,Arial}
.wrap{position:fixed; top:10px; left:0; right:0; pointer-events:none}
.container{width:var(--bugw); margin:0 auto; display:grid; gap:10px}

/* social (colors kept) */
/* Social bar base style */
.socialbar{
  display:inline-grid; grid-auto-flow:column; gap:10px; align-items:center;
  padding:6px 12px;
  background:linear-gradient(180deg,rgba(0,0,0,.65),rgba(0,0,0,.65));
  border:1px solid rgba(255,200,0,.45); border-radius:999px;
  box-shadow:0 6px 16px rgba(0,0,0,.35), 0 0 14px rgba(255,215,0,.25);
  margin: 0; /* Let flex container handle positioning */
}
.handle{font-size:12px; color:rgba(255,255,255,.85); font-weight:800; letter-spacing:.3px}

/* Brand icon colors */
svg.ig {}
svg.ig defs linearGradient stop:nth-child(1){stop-color:#f58529}
svg.ig defs linearGradient stop:nth-child(2){stop-color:#dd2a7b}
svg.ig defs linearGradient stop:nth-child(3){stop-color:#8134af}
svg.ig defs linearGradient stop:nth-child(4){stop-color:#515bd4}
svg.yt{color:#ff0000}
svg.fb{color:#1877f2}
svg.vb{color:var(--gold1)} /* Volleyball icon color */

/* Top header row layout */
.header-row {
  display: flex; align-items: center; justify-content: space-between;
  margin-bottom: 8px; width: 100%;
}
#social-header { margin-left: 0; }
#next-header { margin-right: 0; }
.handle{font-size:12px; color:rgba(255,255,255,.85); font-weight:800; letter-spacing:.3px}

/* Next Up badge - inline with social bar */
.next-badge {
  display: inline-flex; align-items: center; gap: 6px;
  padding: 6px 14px;
  background: linear-gradient(180deg, rgba(0,0,0,.65), rgba(0,0,0,.65));
  border: 1px solid rgba(255,200,0,.35); border-radius: 999px;
  box-shadow: 0 4px 12px rgba(0,0,0,.3);
  font-size: 11px; font-weight: 700; color: var(--muted);
  transition: opacity 0.3s ease;
}
.next-badge .next-label { color: var(--gold2); text-transform: uppercase; font-size: 10px; }
.next-badge .next-teams { color: var(--text); font-weight: 800; }

/* bug - main scoreboard with center-focused layout */
.bug{
  position:relative;
  display:grid; 
  grid-template-columns: 1fr auto 1fr; /* Equal sides, auto center */
  align-items:center; 
  padding:16px 24px;
  width: 900px; /* Fixed width - never changes */
  min-width: 900px; /* Prevent shrinking */
  max-width: 900px; /* Prevent growing */
  background:linear-gradient(180deg,var(--bgTop),var(--bgBot));
  border-radius:18px; border:1px solid rgba(255,200,0,.35);
  box-shadow:0 10px 24px rgba(0,0,0,.5), 0 0 0 1px rgba(255,255,255,.04);
  overflow: visible; /* Allow seeds to show outside */
  gap: 20px; /* Space between columns */
}

/* Team Sections - Left and Right */
.team-section {
  display: flex;
  align-items: center;
  gap: 12px;
}
.team-section.left {
  justify-content: flex-start;
}
.team-section.right {
  justify-content: flex-end;
}

/* Team Names */
.team-name {
  font-size: clamp(18px, 2.5vw, 22px);
  font-weight: 900;
  line-height: 1;
  letter-spacing: -0.5px;
  text-transform: uppercase;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  max-width: 320px;
  color: var(--text);
}

/* Seed Badges */
.seed-badge {
  font-size: 11px;
  font-weight: 800;
  color: var(--gold2);
  background: rgba(0,0,0,0.5);
  padding: 4px 8px;
  border-radius: 4px;
  white-space: nowrap;
  opacity: 0.9;
}
.seed-badge.hidden { display: none; }

/* Center Score Section */
.score-center {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 4px;
}

/* Main Score - Large and Prominent */
.main-score {
  display: flex;
  align-items: center;
  gap: 8px;
  font-variant-numeric: tabular-nums;
}
.score-num {
  font-size: clamp(42px, 5vw, 56px);
  font-weight: 900;
  letter-spacing: -2px;
  color: var(--text);
  line-height: 1;
}
.score-colon {
  font-size: clamp(36px, 4.5vw, 48px);
  font-weight: 700;
  color: rgba(255,255,255,0.5);
  line-height: 1;
}

/* Set Count - Small Below Score */
.set-count {
  display: flex;
  align-items: center;
  gap: 4px;
  font-variant-numeric: tabular-nums;
  opacity: 0.8;
}
.set-count span {
  font-size: 14px;
  font-weight: 700;
  color: var(--text);
}
.set-sep {
  font-size: 12px;
  color: rgba(255,255,255,0.4);
}

/* Serve Indicators - Positioned Absolutely */
.serve-indicator {
  position: absolute;
  width: 20px;
  height: 20px;
  color: var(--gold);
  filter: drop-shadow(0 0 6px rgba(255,215,0,0.6));
  display: none;
  animation: fadeSlide 0.3s ease-out;
}
.serve-indicator.left {
  left: 24px;
  top: 50%;
  transform: translateY(-50%);
}
.serve-indicator.right {
  right: 24px;
  top: 50%;
  transform: translateY(-50%);
}
.serve-indicator.active { display: block; }

/* Seeds sub-bubble - REMOVED, using edge-positioned seeds instead */

/* set history — drawer style with slide animation */
.setsline {
  display: none; /* Hidden until JS shows it */
  gap: 20px; justify-content: center;
  background: linear-gradient(180deg, var(--bgTop), var(--bgBot));
  padding: 12px 24px 8px;
  margin: -14px auto 0;
  width: max-content;
  min-width: 200px;
  
  border: 1px solid rgba(255,200,0,.35);
  border-top: none;
  border-bottom-left-radius: 12px;
  border-bottom-right-radius: 12px;
  
  box-shadow: 0 10px 24px rgba(0,0,0,.5);
  position: relative;
  z-index: 1;
  
  /* Animation setup - starts hidden/above, slides down when visible */
  opacity: 0;
  transform: translateY(-30px);
  transition: opacity 0.5s ease, transform 0.5s ease;
}
.setsline.visible {
  opacity: 1;
  transform: translateY(0);
}
/* Ensure bug is on top */
.bug { z-index: 10; position: relative; }

.set-item {
  font-size: 16px; font-weight: 700; color: var(--muted);
  display: flex; align-items: center; gap: 4px;
}
.set-lbl { color: var(--gold2); font-size: 12px; text-transform: uppercase; margin-right: 2px; opacity: 0.8; }
.set-sc { color: #fff; font-variant-numeric: tabular-nums; }
.set-sc.win { color: var(--gold1); border-bottom: 2px solid var(--gold1); padding-bottom: 1px; }

/* Old next line - hidden, replaced by next-badge */
.next{ display: none; }

/* accent */
.accent{height:3px; width:68%; margin:0 auto;
  background:linear-gradient(90deg,transparent,var(--gold1),var(--gold2),transparent);
  border-radius:3px; opacity:.9}

/* Timeout Banner */
#timeout-banner {
  display: none;
  background: rgba(255, 0, 0, 0.7);
  color: white;
  font-size: 14px;
  font-weight: 800;
  text-transform: uppercase;
  padding: 4px 12px;
  border-radius: 4px;
  margin: -6px auto 0;
  width: max-content;
  z-index: 5;
  box-shadow: 0 4px 8px rgba(0,0,0,0.3);
  animation: pulse 2s infinite ease-in-out;
}

@keyframes pulse {
  0% { transform: scale(1); opacity: 0.9; }
  50% { transform: scale(1.05); opacity: 1; }
  100% { transform: scale(1); opacity: 0.9; }
}

/* animations */
@keyframes flip { 0%{transform:rotateX(-90deg); opacity:0} 100%{transform:rotateX(0); opacity:1} }
@keyframes fadeSlide { 0%{opacity:0; transform:translateY(-4px)} 100%{opacity:1; transform:translateY(0)} }
@keyframes slideDown { 0%{opacity:0; transform:translateY(-20px)} 100%{opacity:1; transform:translateY(0)} }
@keyframes fadeIn { 0%{opacity:0} 100%{opacity:1} }
.flip{ animation:flip .22s ease-out }
.fade{ animation:fadeSlide .18s ease-out }

/* Pre-match mode - simple "Team A vs Team B" text */
.prematch-bar {
  display: flex; align-items: center; justify-content: center; gap: 16px;
  padding: 14px 28px;
  background: linear-gradient(180deg, var(--bgTop), var(--bgBot));
  border-radius: 18px; border: 1px solid rgba(255,200,0,.35);
  box-shadow: 0 10px 24px rgba(0,0,0,.5), 0 0 0 1px rgba(255,255,255,.04);
  transition: opacity 0.4s ease, transform 0.4s ease;
}
.prematch-bar .team-name {
  font-size: 24px; font-weight: 900; text-transform: uppercase;
  letter-spacing: -0.5px; color: var(--text);
}
.prematch-bar .vs {
  font-size: 16px; font-weight: 700; color: var(--gold2);
  text-transform: uppercase; opacity: 0.9;
}

/* Post-match "Next Up" banner */
.postmatch-next {
  text-align: center; padding: 10px 20px;
  font-size: 14px; font-weight: 800; color: var(--gold1);
  background: linear-gradient(180deg, rgba(20,20,20,0.95), rgba(28,28,28,0.95));
  border: 1px solid rgba(255,200,0,.25); border-top: none;
  border-bottom-left-radius: 12px; border-bottom-right-radius: 12px;
  margin: -10px auto 0; width: max-content; min-width: 280px;
  box-shadow: 0 8px 20px rgba(0,0,0,.4);
  opacity: 0; transform: translateY(-10px);
  transition: opacity 0.5s ease, transform 0.5s ease;
}
.postmatch-next.visible { opacity: 1; transform: translateY(0); }
.postmatch-next .next-label { color: var(--muted); font-size: 11px; margin-right: 6px; }

/* State transitions - ONLY opacity and vertical position, NO width changes */
.bug, .prematch-bar { 
  transition: opacity 0.5s ease, transform 0.5s ease; 
  margin: 0 auto; 
}

.bug.hidden { opacity: 0; transform: translateY(-20px); pointer-events: none; display: none; }
.prematch-bar.hidden { opacity: 0; transform: translateY(-10px); display: none; }

/* Removed all transition-init and width animation states */
/* Scoreboard is now permanently 900px wide */

/* Match-change slide-off animation */
@keyframes slideOutLeft {
  0% { transform: translateX(0); opacity: 1; }
  100% { transform: translateX(-120%); opacity: 0; }
}
@keyframes slideOutRight {
  0% { transform: translateX(0); opacity: 1; }
  100% { transform: translateX(120%); opacity: 0; }
}
@keyframes slideInLeft {
  0% { transform: translateX(-120%); opacity: 0; }
  100% { transform: translateX(0); opacity: 1; }
}
@keyframes slideInRight {
  0% { transform: translateX(120%); opacity: 0; }
  100% { transform: translateX(0); opacity: 1; }
}

.bug.match-change .row {
  clip-path: inset(0 0 0 0); /* Contain children within the row */
}
.bug.match-change #t1 { animation: slideOutLeft 0.4s ease-in forwards; }
.bug.match-change #t2 { animation: slideOutRight 0.4s ease-in forwards; }
.bug.match-change #sc1, .bug.match-change #sc2 { animation: fadeSlide 0.4s ease-in reverse forwards; }

.bug.match-reveal #t1 { animation: slideInRight 0.4s ease-out 0.1s forwards; }
.bug.match-reveal #t2 { animation: slideInLeft 0.4s ease-out 0.1s forwards; }
.bug.match-reveal #sc1, .bug.match-reveal #sc2 { animation: fadeSlide 0.4s ease-out 0.1s forwards; }

.bug.reveal { animation: slideDown 0.5s ease-out; }
@media (prefers-reduced-motion: reduce){ .flip,.fade{ animation:none } }
</style>
</head>
<body>
  <div class="wrap"><div class="container">

<!-- Header Row: Social + Next Up -->
<div class="header-row">
  <!-- Social Bar -->
  <div id="social-header" class="socialbar">
    <!-- Instagram -->
    <svg class="ig" aria-hidden="true" viewBox="0 0 24 24" width="16" height="16">
      <defs>
        <linearGradient id="iggrad" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%"/><stop offset="40%"/><stop offset="70%"/><stop offset="100%"/>
        </linearGradient>
      </defs>
      <path fill="url(#iggrad)"
            d="M12 2.2c3.2 0 3.6 0 4.9.1 1.2.1 1.9.3 2.3.5.6.2 1 .5 1.5 1 .5.5.8.9 1 1.5.2.4.4 1.1.5 2.3.1 1.3.1 1.7.1 4.9s0 3.6-.1 4.9c-.1 1.2-.3 1.9-.5 2.3-.2.6-.5 1-1 1.5-.5.5-.9.8-1.5 1-.4.2-1.1.4-2.3.5-1.3.1-1.7.1-4.9.1s-3.6 0-4.9-.1c-1.2-.1-1.9-.3-2.3-.5a3.9 3.9 0 0 1-1.5-1c-.5-.5-.8-.9-1-1.5-.2-.4-.4-1.1-.5-2.3C2.2 15.6 2.2 15.2 2.2 12s0-3.6.1-4.9c.1-1.2.3-1.9.5-2.3.2-.6.5-1 1-1.5.5-.5.9-.8 1.5-1 .4-.2 1.1-.4 2.3-.5C8.4 2.2 8.8 2.2 12 2.2Zm0 5.3a4.5 4.5 0 1 0 0 9 4.5 4.5 0 0 0 0-9Zm6.4-.9a1.2 1.2 0 1 0 0 2.4 1.2 1.2 0 0 0 0-2.4Z"/>
    </svg>

    <!-- YouTube -->
    <svg class="yt" aria-hidden="true" viewBox="0 0 24 24" width="16" height="16">
      <path fill="currentColor"
            d="M23 12s0-3.9-.5-5.7A3.1 3.1 0 0 0 20.8 4C18.9 3.6 12 3.6 12 3.6s-6.9 0-8.8.4A3.1 3.1 0 0 0 1.5 6.3C1 8.1 1 12 1 12s0 3.9.5 5.7c.2.9.9 1.6 1.7 1.9 1.9.4 8.8.4 8.8.4s6.9 0 8.8-.4a3.1 3.1 0 0 0 1.7-1.9c.5-1.8.5-5.7.5-5.7ZM9.8 15.5V8.5l6 3.5-6 3.5Z"/>
    </svg>

    <!-- Facebook -->
    <svg class="fb" aria-hidden="true" viewBox="0 0 24 24" width="16" height="16">
      <path fill="currentColor"
            d="M22 12a10 10 0 1 0-11.6 9.9v-7h-2.3V12h2.3V9.7c0-2.3 1.4-3.6 3.5-3.6 1 0 2 .2 2 .2v2.2h-1.1c-1.1 0-1.4.7-1.4 1.4V12h2.4l-.4 2.9h-2v7A10 10 0 0 0 22 12Z"/>
    </svg>

    <div class="handle">@BeachVolleyballMedia</div>
  </div>
  
  <!-- Next Up Badge -->
  <div id="next-header" class="next-badge">
    <span class="next-label">Next:</span>
    <span id="next-teams" class="next-teams">TBD vs TBD</span>
  </div>
</div>

<!-- Pre-match mode: Simple team names display (shown when score is 0-0) -->
<div id="prematch" class="prematch-bar">
  <span class="team-name" id="pm-t1">Team 1</span>
  <span class="vs">vs</span>
  <span class="team-name" id="pm-t2">Team 2</span>
</div>

    <div id="scorebug" class="bug hidden">
      <!-- Left Team Section -->
      <div class="team-section left">
        <div class="seed-badge" id="seed1-badge">#1</div>
        <div class="team-name" id="t1">TEAM 1</div>
      </div>
      
      <!-- Center Score Section -->
      <div class="score-center">
        <div class="main-score">
          <span class="score-num" id="sc1">0</span>
          <span class="score-colon">:</span>
          <span class="score-num" id="sc2">0</span>
        </div>
        <div class="set-count" id="set-count">
          <span id="sets1">0</span>
          <span class="set-sep">:</span>
          <span id="sets2">0</span>
        </div>
      </div>
      
      <!-- Right Team Section -->
      <div class="team-section right">
        <div class="team-name" id="t2">TEAM 2</div>
        <div class="seed-badge" id="seed2-badge">#2</div>
      </div>
      
      <!-- Serve Indicators (positioned absolutely) -->
      <svg class="serve-indicator left" id="serve-left" viewBox="0 0 24 24">
        <path fill="currentColor" d="M12,2A10,10 0 0,0 2,12A10,10 0 0,0 12,22A10,10 0 0,0 22,12A10,10 0 0,0 12,2M7,16.03C7.5,15.7 8.11,15.5 8.75,15.5C10.74,15.5 12.35,17.11 12.35,19.1C12.35,20.25 11.81,21.27 10.96,21.92C8.71,21.05 7,18.78 7,16.03M9.77,2.27C11.53,3.31 12.89,5.03 13.56,7.09C13.88,8.12 14.07,9.15 14.1,10.15L15.42,12.78C15.8,11.39 16.5,10.09 17.5,9.09C18.15,8.44 18.9,7.91 19.74,7.56C18.4,4.5 15.43,2.37 12,2.05C11.23,1.96 10.46,2.04 9.77,2.27M12,20C11.97,20 11.94,20 11.91,20C12.36,18.57 11.83,17.06 10.63,16.14C9.43,15.22 7.78,14.97 6.4,15.55C5.03,16.13 4.14,17.44 4.09,18.94C4.09,19.29 4.13,19.64 4.19,19.97C6.18,21.25 8.97,21.25 12,20M17.58,19.53C18.33,18.39 18.55,17.03 18.17,15.75C17.8,14.47 16.88,13.46 15.65,12.94C15.21,12.75 14.73,12.65 14.25,12.65C13.4,12.65 12.55,12.95 11.86,13.53C11.17,14.11 10.74,14.9 10.64,15.74C10.53,16.59 10.77,17.43 11.29,18.11C11.82,18.79 12.59,19.2 13.43,19.25C15.03,19.33 16.5,19.2 17.58,19.53M18.86,18.19C20.18,16.63 21,14.59 21,12.35C21,11.53 20.89,10.73 20.67,9.97C19.31,10.66 18.23,11.75 17.54,13.11C16.86,14.47 16.71,15.91 17.13,17.22C17.55,18.53 18.47,19.54 19.68,20.08C19.38,19.49 19.11,18.86 18.86,18.19M2.81,10.42C3.19,8.71 4.15,7.19 5.5,6.07C6.84,4.95 8.43,4.31 10.05,4.31C10.77,4.31 11.47,4.45 12.13,4.72C12.44,5.65 12.56,6.66 12.45,7.66C12.34,8.66 12,9.6 11.47,10.41C10.93,11.23 10.24,11.86 9.42,12.28C8.6,12.7 7.71,12.89 6.81,12.83C5.9,12.77 5.03,12.48 4.25,11.96C3.7,11.59 3.21,11.07 2.81,10.42M5.42,3.32C4.33,4.38 3.5,5.68 3,7.12C4.19,7.69 5.5,7.86 6.75,7.56C8,7.27 9.07,6.54 9.77,5.5C10.47,4.45 10.7,3.22 10.43,2.05C8.61,1.96 6.88,2.41 5.42,3.32Z" />
      </svg>
      <svg class="serve-indicator right" id="serve-right" viewBox="0 0 24 24">
        <path fill="currentColor" d="M12,2A10,10 0 0,0 2,12A10,10 0 0,0 12,22A10,10 0 0,0 22,12A10,10 0 0,0 12,2M7,16.03C7.5,15.7 8.11,15.5 8.75,15.5C10.74,15.5 12.35,17.11 12.35,19.1C12.35,20.25 11.81,21.27 10.96,21.92C8.71,21.05 7,18.78 7,16.03M9.77,2.27C11.53,3.31 12.89,5.03 13.56,7.09C13.88,8.12 14.07,9.15 14.1,10.15L15.42,12.78C15.8,11.39 16.5,10.09 17.5,9.09C18.15,8.44 18.9,7.91 19.74,7.56C18.4,4.5 15.43,2.37 12,2.05C11.23,1.96 10.46,2.04 9.77,2.27M12,20C11.97,20 11.94,20 11.91,20C12.36,18.57 11.83,17.06 10.63,16.14C9.43,15.22 7.78,14.97 6.4,15.55C5.03,16.13 4.14,17.44 4.09,18.94C4.09,19.29 4.13,19.64 4.19,19.97C6.18,21.25 8.97,21.25 12,20M17.58,19.53C18.33,18.39 18.55,17.03 18.17,15.75C17.8,14.47 16.88,13.46 15.65,12.94C15.21,12.75 14.73,12.65 14.25,12.65C13.4,12.65 12.55,12.95 11.86,13.53C11.17,14.11 10.74,14.9 10.64,15.74C10.53,16.59 10.77,17.43 11.29,18.11C11.82,18.79 12.59,19.2 13.43,19.25C15.03,19.33 16.5,19.2 17.58,19.53M18.86,18.19C20.18,16.63 21,14.59 21,12.35C21,11.53 20.89,10.73 20.67,9.97C19.31,10.66 18.23,11.75 17.54,13.11C16.86,14.47 16.71,15.91 17.13,17.22C17.55,18.53 18.47,19.54 19.68,20.08C19.38,19.49 19.11,18.86 18.86,18.19M2.81,10.42C3.19,8.71 4.15,7.19 5.5,6.07C6.84,4.95 8.43,4.31 10.05,4.31C10.77,4.31 11.47,4.45 12.13,4.72C12.44,5.65 12.56,6.66 12.45,7.66C12.34,8.66 12,9.6 11.47,10.41C10.93,11.23 10.24,11.86 9.42,12.28C8.6,12.7 7.71,12.89 6.81,12.83C5.9,12.77 5.03,12.48 4.25,11.96C3.7,11.59 3.21,11.07 2.81,10.42M5.42,3.32C4.33,4.38 3.5,5.68 3,7.12C4.19,7.69 5.5,7.86 6.75,7.56C8,7.27 9.07,6.54 9.77,5.5C10.47,4.45 10.7,3.22 10.43,2.05C8.61,1.96 6.88,2.41 5.42,3.32Z" />
      </svg>
    </div>
    
        <!-- Edge-positioned seeds (outside rows, inside bug for proper positioning) -->
    <span id="seed1-edge" class="seed-edge hidden">#1</span>
    <span id="seed2-edge" class="seed-edge hidden">#2</span>
    </div>


    <div id="setsline" class="setsline"></div>
    <div id="timeout-banner">In Timeout</div>
    <!-- Removed old "next" div - now using header-row next-badge instead -->
    <div class="accent"></div>

<!-- Removed postmatch-next - next match info now in header-row -->

  </div></div>

<script>
const SRC = "/score.json"; const NEXT_SRC = "/next.json"; const LABEL_SRC = "/label.json";
const POLL_MS = 1000;
const POSTMATCH_DELAY_MS = 3 * 60 * 1000; // 3 minutes after match ends

/* Overlay State Machine: prematch | live | postmatch */
let overlayState = 'prematch'; // Start in prematch mode
let postmatchTimer = null;
let isFirstLoad = true; // Detect mid-match join

/* prev values + persistent server */
let prev = { a:null, b:null, set:-1 };
let lastServer = null; // 'A' | 'B' | null
let lastSetLinesKey = "";
let currentTeam1 = "";
let currentTeam2 = "";
let lastMatchKey = ""; // Track match changes

/* helpers */
async function fetchJSON(u){ const r=await fetch(u,{cache:'no-store'}); if(!r.ok) throw new Error(r.status); return r.json(); }
function applyText(el, v, cls){ if(!el) return; const s=String(v ?? ''); if(el.textContent!==s){ el.textContent=s; if(cls){ el.classList.remove(cls); void el.offsetWidth; el.classList.add(cls); } } }
function setWon(a,b,t){ return Math.max(a,b) >= t && Math.abs(a-b) >= 2; }
function cleanName(n){ return (n||"").replace(/\s*\(.*?\)\s*/g," ").replace(/\s{2,}/g," ").trim(); }

/* Smart truncate: shows ONLY last names for scoreboard
   Format: "MOTA / STRAUSS"
   The user now wants only last names displayed on the main scoreboard. */
function abbreviateName(teamName, maxLen = 30) {
  if (!teamName) return "";
  
  // Split by "/" for partner teams
  const players = teamName.split("/").map(p => p.trim());
  
  const abbreviated = players.map(player => {
    // DO NOT abbreviate if it looks like a TBD placeholder
    const lower = player.toLowerCase();
    if (lower.includes("winner") || lower.includes("loser") || 
        lower.includes("team ") || lower.includes("seed ") ||
        lower.includes("match ")) {
      return player;
    }

    const parts = player.split(/\s+/);
    if (parts.length < 2) return player; // Single name, keep as is
    
    // Return ONLY the last name
    return parts[parts.length - 1];
  });
  
  let result = abbreviated.join(" / ");
  
  // Final truncation check for extreme cases
  if (result.length > maxLen) {
    result = result.substring(0, maxLen - 3) + "...";
  }
  return result;
}

/* ==================== OVERLAY STATE MACHINE ==================== */

// Get DOM elements
function getOverlayElements() {
  return {
    prematch: document.getElementById('prematch'),
    scorebug: document.getElementById('scorebug'),
    pmT1: document.getElementById('pm-t1'),
    pmT2: document.getElementById('pm-t2')
    // postmatchNext and postmatchTeams removed - using header-row next-badge instead
  };
}

// Transition to LIVE mode (shows full scoreboard)
// Transition to Live: Dynamic slide/expand animation
function transitionToLive(animate = true) {
  if (overlayState === 'live') return;
  console.log('[Overlay] Transition: ' + overlayState + ' → live');
  
  const els = getOverlayElements();
  overlayState = 'live';
  
  // Hide prematch bar
  if (els.prematch) {
    els.prematch.classList.add('hidden');
    setTimeout(() => { els.prematch.style.display = 'none'; }, 500);
  }
  
  // Show scorebug with animation
  if (els.scorebug) {
    els.scorebug.style.display = ''; // Ensure display is not 'none'
    if (animate) {
      // Simple fade-in, no width animation
      els.scorebug.classList.remove('hidden');
    } else {
      // No animation (mid-match join)
      els.scorebug.classList.remove('hidden');
    }
  }
  
  // Clear any postmatch timer
  if (postmatchTimer) {
    clearTimeout(postmatchTimer);
    postmatchTimer = null;
  }
}

// Transition back to Prematch (for 0-0 resets in Set 1)
function transitionToPrematch(animate = true) {
  if (overlayState === 'prematch') return;
  console.log('[Overlay] Transition: ' + overlayState + ' → prematch (Score Reset)');
  
  const els = getOverlayElements();
  overlayState = 'prematch';
  
  if (els.scorebug) {
    // Simple fade-out, no width animation
    els.scorebug.classList.add('hidden');
    setTimeout(() => { els.scorebug.style.display = 'none'; }, 500);
  }
  
  if (els.prematch) {
    els.prematch.style.display = '';
    void els.prematch.offsetWidth;
    els.prematch.classList.remove('hidden');
  }
}

// Transition to POSTMATCH mode (keeps final score visible, waits for Swift to advance)
function transitionToPostmatch(nextTeam1, nextTeam2) {
  if (overlayState === 'postmatch') return;
  console.log('[Overlay] Transition: ' + overlayState + ' → postmatch');
  
  overlayState = 'postmatch';
  
  // Keep scorebug visible with final score
  // Next match info is shown in header-row next-badge
  // Swift handles the 3-minute hold and queue advancement
  
  // Optional: Start a fallback timer in case Swift doesn't advance
  postmatchTimer = setTimeout(() => {
    console.log('[Overlay] Postmatch timeout - waiting for Swift to advance queue');
  }, POSTMATCH_DELAY_MS);
}

// Transition to PREMATCH mode (shows only team names)
function transitionToPrematch(team1, team2) {
  console.log('[Overlay] Transition: ' + overlayState + ' → prematch');
  
  const els = getOverlayElements();
  overlayState = 'prematch';
  
  // Update prematch bar with team names
  if (els.pmT1) els.pmT1.textContent = abbreviateName(cleanName(team1)) || 'Team 1';
  if (els.pmT2) els.pmT2.textContent = abbreviateName(cleanName(team2)) || 'Team 2';
  
  // Hide scorebug
  if (els.scorebug) {
    els.scorebug.classList.add('hidden');
  }
  
  // Show prematch bar
  if (els.prematch) {
    els.prematch.classList.remove('hidden');
  }
  
  // Clear timer
  if (postmatchTimer) {
    clearTimeout(postmatchTimer);
    postmatchTimer = null;
  }
}

// Check if match has ended (one team won required number of sets)
function checkMatchEnd(setHistory, setsToWin = 2) {
  if (!setHistory || !setHistory.length) return false;
  
  let team1Sets = 0, team2Sets = 0;
  setHistory.forEach(score => {
    const [a, b] = String(score).split('-').map(Number);
    if (a > b) team1Sets++;
    else if (b > a) team2Sets++;
  });
  
  // Use setsToWin from match data (default 2 for best-of-3)
  return team1Sets >= setsToWin || team2Sets >= setsToWin;
}

// Check if score is 0-0 (pre-match state)
function isZeroZero(score1, score2) {
  return (parseInt(score1) || 0) === 0 && (parseInt(score2) || 0) === 0;
}

function completedSetLines(A,B){
  const a1=A.game1||0,b1=B.game1||0, a2=A.game2||0,b2=B.game2||0, a3=A.game3||0,b3=B.game3||0;
  const out=[]; if(setWon(a1,b1,21)) out.push(`${a1}-${b1}`); if(setWon(a2,b2,21)) out.push(`${a2}-${b2}`); if(setWon(a3,b3,15)) out.push(`${a3}-${b3}`);
  return out;
}

// Check if a set is actually completed (score reached target with win-by-2 or hit cap)
function isSetComplete(scoreA, scoreB, pointsPerSet = 21, pointCap = null) {
  const maxScore = Math.max(scoreA, scoreB);
  const diff = Math.abs(scoreA - scoreB);
  
  // If there's a cap and someone hit it, set is complete
  if (pointCap && maxScore >= pointCap) {
    return true;
  }
  
  // Otherwise, need to reach pointsPerSet AND have 2+ point lead
  return maxScore >= pointsPerSet && diff >= 2;
}

// Filter setHistory to only include completed sets
function filterCompletedSets(lines, pointsPerSet = 21, pointCap = null) {
  if (!lines || !lines.length) return [];
  
  return lines.filter(scoreStr => {
    const [as, bs] = String(scoreStr).split('-');
    const a = parseInt(as) || 0;
    const b = parseInt(bs) || 0;
    return isSetComplete(a, b, pointsPerSet, pointCap);
  });
}

function buildSetChips(lines, pointsPerSet = 21, pointCap = null, currentScore1 = 0, currentScore2 = 0){
  const host=document.getElementById('setsline'); if(!host) return;
  
  // Debug: log what we're receiving
  console.log('[SetChips] Raw lines:', lines, 'pointsPerSet:', pointsPerSet, 'pointCap:', pointCap, 'currentScores:', currentScore1, currentScore2);
  
  // Step 1: Filter out the CURRENT LIVE SET (if last entry matches current scores)
  let filteredLines = lines ? [...lines] : [];
  if (filteredLines.length > 0) {
    const lastEntry = String(filteredLines[filteredLines.length - 1]);
    const [as, bs] = lastEntry.split('-');
    const a = parseInt(as) || 0;
    const b = parseInt(bs) || 0;
    // Check if last entry matches current scores (it's the live set)
    if ((a === currentScore1 && b === currentScore2) || (a === currentScore2 && b === currentScore1)) {
      // Only remove if it's NOT a completed set yet
      // If it IS complete, we want to show it in history now!
      if (!isSetComplete(a, b, pointsPerSet, pointCap)) {
        console.log('[SetChips] Removing live (incomplete) set from history:', lastEntry);
        filteredLines.pop(); // Remove the current live set
      } else {
        console.log('[SetChips] Keeping live (completed) set in history:', lastEntry);
      }
    }
  }
  
  // Step 2: Filter to only show COMPLETED sets (not live/in-progress)
  const completedLines = filterCompletedSets(filteredLines, pointsPerSet, pointCap);
  console.log('[SetChips] After filtering:', completedLines);
  
  // Hide if no completed sets
  if(!completedLines || !completedLines.length){ 
    if (host.classList.contains('visible')) {
      host.classList.remove('visible');
      // Hide display after transition completes
      setTimeout(() => { host.style.display = 'none'; }, 500);
    }
    lastSetLinesKey=""; 
    return; 
  }
  
  const key = JSON.stringify(completedLines);
  if(key === lastSetLinesKey) return;
  
  // Build the set chips HTML
  host.innerHTML = completedLines.map((t,i)=>{ 
    const [as,bs]=String(t).split('-'); 
    const a=+as||0, b=+bs||0; 
    const wa = a>b ? ' win' : '';
    const wb = b>a ? ' win' : '';
    return `<div class="set-item">
      <span class="set-lbl">Set ${i+1}</span>
      <span class="set-sc${wa}">${a}</span><span class="set-sc">-</span><span class="set-sc${wb}">${b}</span>
    </div>`; 
  }).join('<div style="width:1px;height:14px;background:rgba(255,255,255,0.15)"></div>');
  
  // Show with animation (slight delay for the transition to work)
  host.style.display = 'flex';
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      host.classList.add('visible');
    });
  });
  
  lastSetLinesKey = key;
}

/* renderer */
function applyData(d){
  if(!d) return;
  
  // Safety check: ensure we have at least team names before updating
  // This prevents the "white flash" where overlay renders empty/broken state
  if (!d.team1 && !d.team2) {
    console.log('[Overlay] Skipping update - missing team names');
    return;
  }

  // Scores - move up to determine naming logic
  const score1 = d.score1 || 0;
  const score2 = d.score2 || 0;
  const isZero = isZeroZero(score1, score2);
  const setNum = d.setNumber || 1;

  // Names - show full names in prematch (0-0, Set 1), abbreviate once game starts
  const useAbbr = !isZero || setNum > 1;
  const name1 = useAbbr ? (abbreviateName(cleanName(d.team1)) || 'Team 1') : (cleanName(d.team1) || 'Team 1');
  const name2 = useAbbr ? (abbreviateName(cleanName(d.team2)) || 'Team 2') : (cleanName(d.team2) || 'Team 2');
  
  // Update header next-badge - match the abbreviation logic
  const nextTeams = document.getElementById('next-teams');
  const nextHeader = document.getElementById('next-header');
  
  // Hide the entire 'Next' badge if there's no next match
  if (!d.nextMatch || d.nextMatch.trim() === '' || d.nextMatch === 'TBD vs TBD') {
    if (nextHeader) {
      nextHeader.style.opacity = '0';
      setTimeout(() => { nextHeader.style.display = 'none'; }, 300);
    }
  } else {
    // Show the badge
    if (nextHeader) {
      nextHeader.style.display = '';
      setTimeout(() => { nextHeader.style.opacity = '1'; }, 10);
    }
    
    if (nextTeams) {
      if (!useAbbr) {
         // Spell everything out in prematch
         applyText(nextTeams, d.nextMatch, 'fade');
      } else {
         // Abbreviate when live
         const nextArr = d.nextMatch.split(/\s+vs\s+/);
         if (nextArr.length === 2) {
           applyText(nextTeams, abbreviateName(nextArr[0], 40) + ' vs ' + abbreviateName(nextArr[1], 40), 'fade');
         } else {
           applyText(nextTeams, abbreviateName(d.nextMatch, 80), 'fade');
         }
      }
    }
  }
  
  // Debug: Log what we're about to update
  console.log('[Overlay] Updating team names:', { name1, name2, team1: d.team1, team2: d.team2 });
  
  // Update scorebug team names
  applyText(document.getElementById('t1'), name1, 'fade');
  applyText(document.getElementById('t2'), name2, 'fade');
  
  // Update prematch bar team names
  const els = getOverlayElements();
  if (els.pmT1) els.pmT1.textContent = name1;
  if (els.pmT2) els.pmT2.textContent = name2;
  }
  
  // Seeds - update seed badges
  const seed1Badge = document.getElementById('seed1-badge');
  const seed2Badge = document.getElementById('seed2-badge');
  const hasSeed1 = d.seed1 && d.seed1.toString().trim() !== '';
  const hasSeed2 = d.seed2 && d.seed2.toString().trim() !== '';
  
  if (seed1Badge) {
    if (hasSeed1) {
      seed1Badge.textContent = `#${d.seed1}`;
      seed1Badge.classList.remove('hidden');
    } else {
      seed1Badge.classList.add('hidden');
    }
  }
  if (seed2Badge) {
    if (hasSeed2) {
      seed2Badge.textContent = `#${d.seed2}`;
      seed2Badge.classList.remove('hidden');
    } else {
      seed2Badge.classList.add('hidden');
    }
  }
  
  // Set Count - update sets won
  const sets1El = document.getElementById('sets1');
  const sets2El = document.getElementById('sets2');
  if (sets1El) sets1El.textContent = d.setsA || 0;
  if (sets2El) sets2El.textContent = d.setsB || 0;
  
  // Track current teams and detect match changes
  const matchKey = d.team1 + '|' + d.team2;
  const isNewMatch = matchKey !== lastMatchKey && lastMatchKey !== "";
  
  if (isNewMatch && overlayState === 'live') {
    // Trigger slide-off animation for old names
    const scorebug = document.getElementById('scorebug');
    if (scorebug) {
      scorebug.classList.add('match-change');
      
      // After slide-out completes, update content and slide in
      setTimeout(() => {
        scorebug.classList.remove('match-change');
        
        // Now update the actual text content
        applyText(document.getElementById('t1'), name1);
        applyText(document.getElementById('t2'), name2);
        applyText(document.getElementById('sc1'), score1);
        applyText(document.getElementById('sc2'), score2);
        
        // Trigger slide-in animation
        scorebug.classList.add('match-reveal');
        setTimeout(() => {
          scorebug.classList.remove('match-reveal');
        }, 500);
      }, 450);
    }
    
    lastMatchKey = matchKey;
    currentTeam1 = d.team1;
    currentTeam2 = d.team2;
    return; // Skip normal text update since animation handles it
  }
  
  if (lastMatchKey === "") {
    lastMatchKey = matchKey;
    currentTeam1 = d.team1;
    currentTeam2 = d.team2;
  }

  // Scores (already handled above)
  applyText(document.getElementById('sc1'), score1, 'flip');
  applyText(document.getElementById('sc2'), score2, 'flip');

  // Set History Drawer - pass pointsPerSet and current scores so we only show COMPLETED sets
  const pointsPerSet = d.pointsPerSet || 21;
  const pointCap = d.pointCap || null;
  buildSetChips(d.setHistory, pointsPerSet, pointCap, score1, score2);
  
  // ==================== STATE MACHINE LOGIC ====================
  
  const timeoutBanner = document.getElementById('timeout-banner');

  // First load: detect if joining mid-match
  if (isFirstLoad) {
    isFirstLoad = false;
    if (!isZero) {
      console.log('[Overlay] Mid-match join detected, showing scoreboard');
      transitionToLive(false); 
    } else {
      console.log('[Overlay] Starting in prematch mode (0-0)');
      if (els.scorebug) els.scorebug.style.display = 'none';
      if (els.prematch) els.prematch.classList.remove('hidden');
    }
  }
  
  // Handle 0-0 states
  if (isZero) {
    if (setNum === 1) {
      // Revert to prematch if score is reset to 0-0 in Set 1
      if (overlayState === 'live') {
        transitionToPrematch(true);
      }
      if (timeoutBanner) timeoutBanner.style.display = 'none';
    } else {
      // In later sets, show Timeout banner if score is 0-0
      if (timeoutBanner) {
        timeoutBanner.textContent = `Set ${setNum} Timeout`;
        timeoutBanner.style.display = 'block';
      }
    }
  } else {
    // Score is NOT 0-0: Hide timeout banner and ensure we are in live mode
    if (timeoutBanner) timeoutBanner.style.display = 'none';
    
    if (overlayState === 'prematch') {
      console.log('[Overlay] Point scored! Transitioning to live');
      transitionToLive(true);
    }
  }
  
  // In live mode: check for match end
  if (overlayState === 'live') {
    const setsToWin = d.setsToWin || 2;
    if (checkMatchEnd(d.setHistory, setsToWin)) {
      const nextTeam1 = d.nextTeam1 || 'TBD';
      const nextTeam2 = d.nextTeam2 || 'TBD';
      console.log('[Overlay] Match ended, transitioning to postmatch');
      transitionToPostmatch(nextTeam1, nextTeam2);
    }
  }
  
  // ==================== END STATE MACHINE ====================
  
  // Serve indicator - show on left or right
  const srv = (d.serve||"").toLowerCase();
  const serveLeft = document.getElementById('serve-left');
  const serveRight = document.getElementById('serve-right');
  
  if(serveLeft && serveRight) {
      const isHome = srv.includes('home') || srv.includes('team1');
      const isAway = srv.includes('away') || srv.includes('team2');
      serveLeft.classList.toggle('active', isHome);
      serveRight.classList.toggle('active', isAway);
  }
}

/* ticks */
async function tick(){ 
    try{ 
        const d=await fetchJSON(SRC); 
        if(d) applyData(d); 
    }catch(e){
        console.log(e);
    } finally{ 
        setTimeout(tick,POLL_MS); 
    } 
}

// label (top‑left)
async function tickLabel(){
  try{
    const o = await fetchJSON(LABEL_SRC);
    const label = (o && typeof o.label === 'string') ? o.label.trim() : '';
    const el = document.getElementById('label');
    el.style.display = label ? '' : 'none';
    if(label) applyText(el, label, 'fade');
  }catch(_){} finally{ setTimeout(tickLabel, Math.max(POLL_MS*2, 1500)); }
}

// next (with label)
async function tickNext(){
  try{
    const o = await fetchJSON(SRC); // We check score.json for nextMatch prop now too
    if(o && o.nextMatch) {
        applyText(document.getElementById('next'), `Next: ${o.nextMatch}`, 'fade');
    }
  }catch(_){} finally{ setTimeout(tickNext, Math.max(POLL_MS*2, 1500)); }
}

tick();
tickLabel();
tickNext();
</script>
</body>
</html>
"""#
}
