//
//  WebSocketHub.swift
//  MultiCourtScore v2
//
//  Local HTTP server for OBS overlay endpoints
//

import Foundation
import Vapor

final class WebSocketHub {
    static let shared = WebSocketHub()
    
    // App state reference
    weak var appViewModel: AppViewModel?
    
    // Vapor app
    private var app: Application?
    private var isRunning = false
    
    // Score data cache for overlays
    private var latestScoreData: [Int: Data] = [:]
    
    // Hold mechanism for showing final scores
    private var holdQueue: [Int: (data: [String: Any], expires: Date)] = [:]
    
    private init() {}
    
    // MARK: - Lifecycle
    
    func start(with viewModel: AppViewModel, port: Int = NetworkConstants.webSocketPort) {
        guard !isRunning else { return }
        appViewModel = viewModel
        
        let app = Application(.development)
        self.app = app
        
        // Configure server
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = port
        
        // Silence Vapor's default logging
        app.logger.logLevel = .error
        
        // Install routes
        installRoutes(app)
        
        // Start server in background
        DispatchQueue.global(qos: .utility).async {
            do {
                try app.start()
                self.isRunning = true
                print("🌐 Overlay server running at http://localhost:\(port)")
            } catch {
                print("❌ Failed to start overlay server: \(error)")
            }
        }
    }
    
    func stop() {
        app?.shutdown()
        app = nil
        isRunning = false
        print("🛑 Overlay server stopped")
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
        app.get("overlay", "court", ":id") { req -> Response in
            guard let idStr = req.parameters.get("id") else {
                return Response(status: .notFound)
            }
            let html = self.generateOverlayHTML(courtId: idStr)
            var response = Response(status: .ok)
            response.headers.contentType = .html
            response.body = .init(string: html)
            return response
        }
        
        // Redirect without trailing slash
        app.get("overlay", "court", ":id", "") { req -> Response in
            guard let idStr = req.parameters.get("id") else {
                return Response(status: .notFound)
            }
            let html = self.generateOverlayHTML(courtId: idStr)
            var response = Response(status: .ok)
            response.headers.contentType = .html
            response.body = .init(string: html)
            return response
        }
        
        // Score JSON endpoint
        app.get("overlay", "court", ":id", "score.json") { [weak self] req async throws -> Response in
            guard let self,
                  let vm = self.appViewModel,
                  let idStr = req.parameters.get("id"),
                  let courtId = Int(idStr),
                  let courtIdx = vm.courtIndex(for: courtId),
                  let activeIdx = vm.courts[courtIdx].activeIndex,
                  activeIdx >= 0,
                  activeIdx < vm.courts[courtIdx].queue.count
            else {
                return Response(status: .ok)
            }
            
            let url = vm.courts[courtIdx].queue[activeIdx].apiURL
            
            do {
                let (data, response) = try await URLSession.shared.data(from: self.cacheBusted(url))
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    return Response(status: .badGateway)
                }
                
                var r = Response(status: .ok)
                r.headers.contentType = .json
                r.headers.cacheControl = .init(noStore: true)
                r.body = .init(data: data)
                return r
            } catch {
                return Response(status: .badGateway)
            }
        }
        
        // Label endpoint
        app.get("overlay", "court", ":id", "label.json") { [weak self] req async throws -> Response in
            guard let self,
                  let vm = self.appViewModel,
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
        
        // Next match endpoint
        app.get("overlay", "court", ":id", "next.json") { [weak self] req async throws -> Response in
            guard let self,
                  let vm = self.appViewModel,
                  let idStr = req.parameters.get("id"),
                  let courtId = Int(idStr),
                  let courtIdx = vm.courtIndex(for: courtId),
                  let activeIdx = vm.courts[courtIdx].activeIndex
            else {
                return try Self.json(["a": NSNull(), "b": NSNull(), "label": NSNull()])
            }
            
            let nextIdx = activeIdx + 1
            guard nextIdx < vm.courts[courtIdx].queue.count else {
                return try Self.json(["a": NSNull(), "b": NSNull(), "label": NSNull()])
            }
            
            let nextMatch = vm.courts[courtIdx].queue[nextIdx]
            
            do {
                let (data, _) = try await URLSession.shared.data(from: nextMatch.apiURL)
                let (a, b) = Self.extractNames(from: data)
                
                return try Self.json([
                    "a": a ?? NSNull(),
                    "b": b ?? NSNull(),
                    "label": nextMatch.label ?? NSNull()
                ])
            } catch {
                return try Self.json([
                    "a": nextMatch.team1Name ?? NSNull(),
                    "b": nextMatch.team2Name ?? NSNull(),
                    "label": nextMatch.label ?? NSNull()
                ])
            }
        }
    }
    
    // MARK: - Helpers
    
    private func cacheBusted(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "_t", value: String(Int(Date().timeIntervalSince1970 * 1000))))
        components.queryItems = items
        return components.url ?? url
    }
    
    private static func json(_ dict: [String: Any]) throws -> Response {
        let data = try JSONSerialization.data(withJSONObject: dict)
        var response = Response(status: .ok)
        response.headers.contentType = .json
        response.headers.cacheControl = .init(noStore: true)
        response.body = .init(data: data)
        return response
    }
    
    private static func extractNames(from data: Data) -> (String?, String?) {
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
            let a = dict["homeTeam"] as? String ?? dict["team1Name"] as? String
            let b = dict["awayTeam"] as? String ?? dict["team2Name"] as? String
            return (a, b)
        }
        
        return (nil, nil)
    }
    
    // MARK: - Overlay HTML
    
    private func generateOverlayHTML(courtId: String) -> String {
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Court \(courtId) Overlay</title>
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                    background: transparent;
                    color: white;
                    overflow: hidden;
                }
                .scoreboard {
                    position: absolute;
                    bottom: 40px;
                    left: 40px;
                    background: linear-gradient(135deg, rgba(0,0,0,0.85) 0%, rgba(20,20,20,0.9) 100%);
                    border-radius: 12px;
                    padding: 16px 24px;
                    min-width: 280px;
                    box-shadow: 0 8px 32px rgba(0,0,0,0.4);
                    border: 1px solid rgba(255,255,255,0.1);
                }
                .team-row {
                    display: flex;
                    align-items: center;
                    justify-content: space-between;
                    padding: 8px 0;
                }
                .team-row:first-child { border-bottom: 1px solid rgba(255,255,255,0.1); }
                .team-name {
                    font-size: 18px;
                    font-weight: 600;
                    max-width: 180px;
                    overflow: hidden;
                    text-overflow: ellipsis;
                    white-space: nowrap;
                }
                .score {
                    font-size: 32px;
                    font-weight: 700;
                    font-variant-numeric: tabular-nums;
                    min-width: 50px;
                    text-align: right;
                }
                .serve-indicator {
                    width: 8px;
                    height: 8px;
                    border-radius: 50%;
                    background: #10B981;
                    margin-right: 8px;
                    opacity: 0;
                    transition: opacity 0.3s;
                }
                .serve-indicator.active { opacity: 1; }
                .set-info {
                    font-size: 12px;
                    color: rgba(255,255,255,0.6);
                    text-align: center;
                    margin-top: 8px;
                    padding-top: 8px;
                    border-top: 1px solid rgba(255,255,255,0.1);
                }
                .hidden { display: none; }
            </style>
        </head>
        <body>
            <div class="scoreboard" id="scoreboard">
                <div class="team-row">
                    <div style="display: flex; align-items: center;">
                        <div class="serve-indicator" id="serve1"></div>
                        <span class="team-name" id="team1">Team A</span>
                    </div>
                    <span class="score" id="score1">0</span>
                </div>
                <div class="team-row">
                    <div style="display: flex; align-items: center;">
                        <div class="serve-indicator" id="serve2"></div>
                        <span class="team-name" id="team2">Team B</span>
                    </div>
                    <span class="score" id="score2">0</span>
                </div>
                <div class="set-info" id="setInfo">Set 1</div>
            </div>
            
            <script>
                const courtId = '\(courtId)';
                const pollInterval = 1500;
                
                async function fetchScore() {
                    try {
                        const res = await fetch(`/overlay/court/${courtId}/score.json?_t=${Date.now()}`);
                        if (!res.ok) return;
                        
                        const data = await res.json();
                        updateDisplay(data);
                    } catch (e) {
                        console.error('Fetch error:', e);
                    }
                }
                
                function updateDisplay(data) {
                    // Handle vMix array format
                    if (Array.isArray(data) && data.length >= 2) {
                        document.getElementById('team1').textContent = data[0].teamName || 'Team A';
                        document.getElementById('team2').textContent = data[1].teamName || 'Team B';
                        document.getElementById('score1').textContent = data[0].score ?? 0;
                        document.getElementById('score2').textContent = data[1].score ?? 0;
                        
                        const setNum = data[0].setNumber || 1;
                        const won1 = data[0].won;
                        const won2 = data[1].won;
                        
                        if (won1 || won2) {
                            document.getElementById('setInfo').textContent = 'FINAL';
                        } else {
                            document.getElementById('setInfo').textContent = `Set ${setNum}`;
                        }
                        return;
                    }
                    
                    // Handle dictionary format
                    if (data.score) {
                        document.getElementById('score1').textContent = data.score.home ?? 0;
                        document.getElementById('score2').textContent = data.score.away ?? 0;
                    }
                    if (data.homeTeam) document.getElementById('team1').textContent = data.homeTeam;
                    if (data.awayTeam) document.getElementById('team2').textContent = data.awayTeam;
                    if (data.status) {
                        document.getElementById('setInfo').textContent = data.status;
                    }
                }
                
                // Start polling
                fetchScore();
                setInterval(fetchScore, pollInterval);
            </script>
        </body>
        </html>
        """
    }
}
