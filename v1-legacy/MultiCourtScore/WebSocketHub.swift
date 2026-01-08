//
//  WebSocketHub.swift
//  MultiCourtScore
//

import Foundation
import Vapor

final class WebSocketHub {
    static let shared = WebSocketHub()

    // App state (to read queues/activeIndex)
    weak var appViewModel: AppViewModel?

    // Vapor app lifetime
    private var app: Application?
    private var isRunning = false

    // When a match finishes we hold the last upstream JSON for 1 minute so viewers can read it
    // key = courtId
    private var holds: [Int: (data: Data, expires: Date)] = [:]
    
    // Hold next match info during final score display
    // key = courtId
    private var nextHolds: [Int: (nextData: [String: Any], expires: Date)] = [:]

    // MARK: - Start/Stop

    /// Start the tiny local HTTP server.
    func start(with vm: AppViewModel, port: Int = 8787) {
        guard !isRunning else { return }
        self.appViewModel = vm

        // Create a fresh application
        let app = Application(.development)
        self.app = app

        // Strip Xcode's flags so Vapor doesn't try to parse them.
        app.environment.arguments = ["serve"]

        app.logger.logLevel = .debug
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = port
        
        // Install routes
        installRoutes(app)

        do {
            try app.start()
            isRunning = true
            print("Local overlay server started at http://127.0.0.1:\(port)")
        } catch {
            print("Failed to start server: \(error)")
            app.shutdown()
            self.app = nil
            isRunning = false
        }
    }

    /// Stop the server.
    func stop() {
        guard isRunning else { return }
        app?.shutdown()
        app = nil
        isRunning = false
    }
    // Treat nil/empty string as JSON null, otherwise return the trimmed string
    private func nullOrString(_ s: String?) -> Any {
        let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? NSNull() : t
    }

    // MARK: - Routes

    private func installRoutes(_ app: Application) {
        // Health
        app.get("health") { _ in "ok" }

        // Redirect to trailing slash
        app.get("overlay","court",":id") { req -> Response in
            guard let id = req.parameters.get("id") else { return Response(status: .badRequest) }
            return req.redirect(to: "/overlay/court/\(id)/")
        }

        // Serve overlay HTML (inject court-specific JSON endpoints)
        app.get("overlay","court",":id","") { [weak self] req -> Response in
            guard
                let self,
                req.parameters.get("id") != nil
            else { return Response(status: .badRequest) }

            var html = Self.bvmOverlayHTML
            // Keep the marker line in the HTML and replace the sources
            html = html.replacingOccurrences(
                of: #"const SRC = "/score.json"; const NEXT_SRC = "/next.json"; const LABEL_SRC = "/label.json";"#,
                with: #"const SRC = "/overlay/court/\#(req.parameters.get("id")!)/score.json"; const NEXT_SRC = "/overlay/court/\#(req.parameters.get("id")!)/next.json"; const LABEL_SRC = "/overlay/court/\#(req.parameters.get("id")!)/label.json";"#
            )
            return Response(status: .ok, body: .init(string: html))
        }

        // Current LABEL (string only), used by UI
        app.get("overlay","court",":id","label.json") { [weak self] req async throws -> Response in
            guard
                let self,
                let vm = self.appViewModel,
                let idStr = req.parameters.get("id"),
                let id = Int(idStr),
                let ci = vm.idxOf(id)
            else { return try Self.json(["label": NSNull()]) }

            // If we're holding (Final) reuse held label if still unexpired
            if let hold = self.holds[id], hold.expires > Date() {
                // Try to read label from the held JSON first; if not present fall back
                if let heldLabel = Self.extractLabel(from: hold.data) {
                    return try Self.json(["label": heldLabel])
                }
                // else fall back to current queue label (if any)
            }

            // Otherwise current queue label (active item if any)
            var label = ""
            if
                let ai = vm.courts[ci].activeIndex,
                ai >= 0, ai < vm.courts[ci].queue.count
            {
                label = vm.courts[ci].queue[ai].label ?? ""
            }
            return try Self.json(["label": (label.isEmpty ? NSNull() : label) as Any])
        }

        // Next match names + label (for "Next" preview)
        app.get("overlay", "court", ":id", "next.json") { [weak self] req async throws -> Response in
            guard
                let self,
                let vm = self.appViewModel,
                let idStr = req.parameters.get("id"),
                let id = Int(idStr),
                let ci = vm.idxOf(id)
            else { return try Self.json(["a": NSNull(), "b": NSNull(), "label": NSNull()]) }
            
            // If we're holding (Final) and have captured next match data, use that
            if let nextHold = self.nextHolds[id], nextHold.expires > Date() {
                return try Self.json(nextHold.nextData)
            }

            let ai = (vm.courts[ci].activeIndex ?? -1)
            let ni = ai + 1
            guard ni < vm.courts[ci].queue.count else {
                // no "next" item
                return try Self.json(["a": NSNull(), "b": NSNull(), "label": NSNull()])
            }

            let url = vm.courts[ci].queue[ni].apiURL
            // Helper to keep only the round/extra text (drop any "A vs B • " prefix)
            func roundOnly(_ raw: String?) -> String? {
                guard var t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
                if let dot = t.lastIndex(of: "•") {
                    let after = t.index(after: dot)
                    t = String(t[after...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return t.isEmpty ? nil : t
            }

            let nextLabel = vm.courts[ci].queue[ni].label
            let labelOut: Any = (roundOnly(nextLabel) as Any?) ?? NSNull()

            do {
                let (data, resp) = try await URLSession.shared.data(from: url)
                guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    // Couldn’t fetch names; return only label
                    return try Self.json(["a": NSNull(), "b": NSNull(), "label": labelOut])
                }

                // Try to read A/B names from upstream JSON (supports both schemas)
                let obj = try JSONSerialization.jsonObject(with: data, options: [])
                let (aName, bName) = Self.extractNames(from: obj)  // <-- your helper that returns (String?, String?)

                let aOut: Any = aName ?? NSNull()
                let bOut: Any = bName ?? NSNull()

                return try Self.json([
                    "a": aOut,
                    "b": bOut,
                    "label": labelOut
                ])
            } catch {
                // On any error, still return label if we have it
                return try Self.json(["a": NSNull(), "b": NSNull(), "label": labelOut])
            }
        }

        // Current match JSON (active queue item) with 3‑min hold after Final
        app.get("overlay","court",":id","score.json") { [weak self] req async throws -> Response in
            guard
                let self,
                let vm = self.appViewModel,
                let idStr = req.parameters.get("id"),
                let id = Int(idStr),
                let ci = vm.idxOf(id)
            else { return Response(status: .notFound) }

            // If we have a valid hold, serve it
            if let hold = self.holds[id], hold.expires > Date() {
                var r = Response(status: .ok)
                r.headers.replaceOrAdd(name: .contentType, value: "application/json")
                r.body = .init(data: hold.data)
                return r
            }

            // Otherwise, fetch the current active match JSON
            guard
                let ai = vm.courts[ci].activeIndex,
                ai >= 0,
                ai < vm.courts[ci].queue.count
            else { return Response(status: .ok) } // empty body keeps previous frame in the browser

            let url = cacheBusted(vm.courts[ci].queue[ai].apiURL)
            do {
                let (data, resp) = try await URLSession.shared.data(from: url)
                guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    return Response(status: .badGateway)
                }

                // Inspect JSON to see if it's final; if so, start a 1‑minute hold with this snapshot
                if Self.jsonLooksFinal(data) {
                    let expiry = Date().addingTimeInterval(60)
                    self.holds[id] = (data: data, expires: expiry)
                    
                    // Also capture the current next match state to freeze it during hold
                    await self.captureNextMatchForHold(courtId: id, expires: expiry)
                }

                var r = Response(status: .ok)
                r.headers.replaceOrAdd(name: .contentType, value: "application/json")
                r.body = .init(data: data)
                return r
            } catch {
                return Response(status: .badGateway)
            }
        }
    }

    // MARK: - Helpers (server)

    // Extract "home/away" (A/B) names from either upstream schema
    private static func extractNames(from obj: Any) -> (String?, String?) {
        // vMix-style array: [ {teamName: ...}, {teamName: ...}, ... ]
        if let arr = obj as? [[String: Any]], arr.count >= 2 {
            let a = arr[0]["teamName"] as? String
            let b = arr[1]["teamName"] as? String
            return (a, b)
        }

        // Dictionary style (fallback)
        if let dict = obj as? [String: Any] {
            let a = (dict["homeTeamName"]
                     ?? dict["team1Name"]
                     ?? (dict["home"] as? [String: Any])?["name"]) as? String
            let b = (dict["awayTeamName"]
                     ?? dict["team2Name"]
                     ?? (dict["away"] as? [String: Any])?["name"]) as? String
            return (a, b)
        }

        return (nil, nil)
    }
    /// JSON envelope helper
    private static func json(_ obj: Any) throws -> Response {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [])
        var r = Response(status: .ok)
        r.headers.replaceOrAdd(name: .contentType, value: "application/json")
        r.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        r.body = .init(data: data)
        return r
    }

    /// Pull a "label" string out of a JSON blob if present (used during hold)
    private static func extractLabel(from data: Data) -> String? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data, options: []),
            let arr = obj as? [[String: Any]],
            arr.count >= 2
        else { return nil }
        // If your upstream has a label, adapt here. Default: none.
        return nil
    }

    /// Prefer teamName; else build “First Last / First Last”.
    private static func bestName(from team: [String: Any]) -> String {
        // Prefer explicit teamName
        if let t = team["teamName"] as? String, !t.isEmpty { return t }

        // Common alternates we’ve seen
        if let t = team["name"] as? String, !t.isEmpty { return t }
        if let t = team["team_name"] as? String, !t.isEmpty { return t }

        // Build "First Last / First Last" from players if present
        if let players = team["players"] as? [[String: Any]], !players.isEmpty {
            let parts = players.compactMap { p -> String? in
                let f = (p["firstname"] as? String) ?? (p["firstName"] as? String) ?? ""
                let l = (p["lastname"]  as? String) ?? (p["lastName"]  as? String) ?? ""
                let full = [f,l].filter{ !$0.isEmpty }.joined(separator: " ")
                return full.isEmpty ? nil : full
            }
            if !parts.isEmpty { return parts.joined(separator: " / ") }
        }

        return "TBD"
    }

    /// Remove anything in parentheses and collapse whitespace.
    static func cleanName(_ name: String?) -> String {
        guard var s = name else { return "TBD" }
        s = s.replacingOccurrences(of: #"\s*\(.*?\)\s*"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "TBD" : s
    }

    /// A conservative “final” detector: vballife-style arrays or dictionaries.
    private static func jsonLooksFinal(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) else { return false }

        // vMix array style: check "status" string on any team
        if let arr = obj as? [[String: Any]] {
            let s1 = (arr.first?["status"] as? String)?.uppercased() ?? ""
            if s1.contains("FINAL") { return true }
            let s2 = (arr.dropFirst().first?["status"] as? String)?.uppercased() ?? ""
            if s2.contains("FINAL") { return true }
            // Also: 21/21 then 15 set counts heuristic
            let a1 = (arr[0]["game1"] as? Int) ?? 0
            let b1 = (arr[1]["game1"] as? Int) ?? 0
            let a2 = (arr[0]["game2"] as? Int) ?? 0
            let b2 = (arr[1]["game2"] as? Int) ?? 0
            let a3 = (arr[0]["game3"] as? Int) ?? 0
            let b3 = (arr[1]["game3"] as? Int) ?? 0
            func setWon(_ a: Int, _ b: Int, _ tgt: Int) -> Bool { max(a,b) >= tgt && abs(a-b) >= 2 }
            if setWon(a1,b1,21) && setWon(a2,b2,21) { return true }
            if setWon(a1,b1,21) && setWon(a3,b3,15) && (a2>0 || b2>0) { return true }
            if setWon(a2,b2,21) && setWon(a3,b3,15) && (a1>0 || b1>0) { return true }
        }

        // Dict style: check top-level "status"
        if let dict = obj as? [String: Any] {
            if let s = (dict["status"] as? String)?.uppercased(), s.contains("FINAL") { return true }
        }

        return false
    }
    // Add a throwaway timestamp so intermediate caches don't serve stale JSON
    private func cacheBusted(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "_ts", value: String(Int(Date().timeIntervalSince1970))))
        comps.queryItems = items
        return comps.url ?? url
    }
    // MARK: - Embedded HTML (raw string so JS regex is fine)
    // NOTE: keep the opening #""" and closing """# exactly — this avoids Swift escape issues for JS regex.
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
  --score-size:38px; --sets-size:14px; --maxw:1040px;
}
html,body{margin:0;background:transparent;color:var(--text);font-family:system-ui,-apple-system,Segoe UI,Roboto,Helvetica,Arial}
.wrap{position:fixed; top:10px; left:0; right:0; pointer-events:none}
.container{width:min(var(--maxw),96vw); margin:0 auto; display:grid; gap:10px}

/* social (colors kept) */
/* Social bar */
.socialbar{
  display:inline-grid; grid-auto-flow:column; gap:10px; align-items:center;
  padding:6px 12px; margin:0 auto;
  background:linear-gradient(180deg,rgba(0,0,0,.65),rgba(0,0,0,.65));
  border:1px solid rgba(255,200,0,.45); border-radius:999px;
  box-shadow:0 6px 16px rgba(0,0,0,.35), 0 0 14px rgba(255,215,0,.25);
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

/* bug */
.bug{
  position:relative;
  display:grid; grid-template-columns: 1fr auto 1fr; align-items:center; column-gap:12px;
  padding:12px 18px;
  background:linear-gradient(180deg,var(--bgTop),var(--bgBot));
  border-radius:18px; border:1px solid rgba(255,200,0,.35);
  box-shadow:0 10px 24px rgba(0,0,0,.5), 0 0 0 1px rgba(255,255,255,.04)
}
/* round label (top-left) */
.matchLabel{
  position:absolute; left:14px; top:-10px;
  font-size:11px; font-weight:800; color:#111;
  background:linear-gradient(180deg,#ffe9a8,#ffd36c);
  border:1px solid rgba(255,200,0,.65); border-radius:999px; padding:2px 8px;
  box-shadow:0 2px 6px rgba(0,0,0,.35)
}

.side{display:grid; align-items:center; column-gap:12px}
.side.left  { grid-template-columns: auto 1fr auto auto; }
.side.right { grid-template-columns: auto auto 1fr auto; }

.name{max-width:36ch; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; font-weight:800}
.score{
  display:inline-block; font-size:var(--score-size); font-weight:900; line-height:1;
  text-shadow:0 1px 0 rgba(0,0,0,.5);
  transform-origin: 50% 60%; backface-visibility: hidden; perspective:600px;
}
.sets{font-size:var(--sets-size); color:var(--muted); font-weight:800}
.mid{display:grid; grid-auto-flow:row; gap:6px; justify-items:center; min-width:0}
.meta{background:linear-gradient(180deg,rgba(0,0,0,.7),rgba(0,0,0,.7));
  border:1px solid rgba(255,200,0,.45); box-shadow:0 3px 8px rgba(0,0,0,.35);
  padding:4px 10px; border-radius:999px; font-size:12px; font-weight:800; color:var(--muted)}

/* server volleyball */
.serve{width:18px; height:18px; filter:drop-shadow(0 1px 1px rgba(0,0,0,.5)); transition:opacity .15s ease}
.serve.off{opacity:0}

/* set history — no animations */
.setsline{display:inline-grid; grid-auto-flow:column; gap:8px; align-items:center; justify-self:center}
.chip{padding:3px 8px; border-radius:999px; font-size:11px; font-weight:800; color:#111;
  background:linear-gradient(180deg,var(--gold1),var(--gold2));
  box-shadow:inset 0 0 0 1px rgba(0,0,0,.25), 0 2px 8px rgba(0,0,0,.25)}
.chip .a,.chip .b{font-weight:700}
.chip.a-win .a{font-weight:900; text-decoration:underline}
.chip.b-win .b{font-weight:900; text-decoration:underline}

/* next line (dark) */
.next{text-align:center; font-size:12px; font-weight:800; color:#111; text-shadow:0 1px 2px rgba(0,0,0,.15)}

/* accent */
.accent{height:3px; width:68%; margin:0 auto;
  background:linear-gradient(90deg,transparent,var(--gold1),var(--gold2),transparent);
  border-radius:3px; opacity:.9}

/* animations */
@keyframes flip { 0%{transform:rotateX(-90deg); opacity:0} 100%{transform:rotateX(0); opacity:1} }
@keyframes fadeSlide { 0%{opacity:0; transform:translateY(-4px)} 100%{opacity:1; transform:translateY(0)} }
.flip{ animation:flip .22s ease-out }
.fade{ animation:fadeSlide .18s ease-out }
@media (prefers-reduced-motion: reduce){ .flip,.fade{ animation:none } }
</style>
</head>
<body>
  <div class="wrap"><div class="container">

<!-- Social -->
<div class="socialbar">
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

    <div class="bug">
      <div class="matchLabel" id="label"> </div>

      <div class="side left">
        <!-- volleyball icon (left) -->
        <svg id="serveA" class="serve off" viewBox="0 0 24 24" aria-hidden="true">
          <defs><linearGradient id="vbGradA" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="var(--gold1)"/><stop offset="100%" stop-color="var(--gold2)"/></linearGradient></defs>
          <g fill="none" stroke="url(#vbGradA)" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <circle cx="12" cy="12" r="9"></circle>
            <path d="M12 3a9 9 0 0 1 9 9"></path>
            <path d="M3 12a9 9 0 0 0 9 9"></path>
            <path d="M5.5 6.5A8.5 8.5 0 0 1 12 9"></path>
            <path d="M18.5 17.5A8.5 8.5 0 0 0 12 15"></path>
            <path d="M15 5a8.5 8.5 0 0 1 4 4.5"></path>
          </g>
        </svg>

        <div class="name" id="nameA">Team A</div>
        <div class="score" id="scoreA">0</div>
        <div class="sets" id="setsA">(0)</div>
      </div>

      <div class="mid">
        <div class="meta" id="meta">Set 1</div>
      </div>

      <div class="side right">
        <div class="sets" id="setsB">(0)</div>
        <div class="score" id="scoreB">0</div>
        <div class="name" id="nameB" style="text-align:right;">Team B</div>

        <!-- volleyball icon (right) -->
        <svg id="serveB" class="serve off" viewBox="0 0 24 24" aria-hidden="true">
          <defs><linearGradient id="vbGradB" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="var(--gold1)"/><stop offset="100%" stop-color="var(--gold2)"/></linearGradient></defs>
          <g fill="none" stroke="url(#vbGradB)" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <circle cx="12" cy="12" r="9"></circle>
            <path d="M12 3a9 9 0 0 1 9 9"></path>
            <path d="M3 12a9 9 0 0 0 9 9"></path>
            <path d="M5.5 6.5A8.5 8.5 0 0 1 12 9"></path>
            <path d="M18.5 17.5A8.5 8.5 0 0 0 12 15"></path>
            <path d="M15 5a8.5 8.5 0 0 1 4 4.5"></path>
          </g>
        </svg>
      </div>
    </div>

    <div id="setsline" class="setsline" style="display:none;"></div>
    <div id="next" class="next">Next: TBD vs TBD</div>
    <div class="accent"></div>

  </div></div>

<script>
const SRC = "/score.json"; const NEXT_SRC = "/next.json"; const LABEL_SRC = "/label.json";
const POLL_MS = 1000;

/* prev values + persistent server */
let prev = { a:null, b:null, set:-1 };
let lastServer = null; // 'A' | 'B' | null
let lastSetLinesKey = "";

/* helpers */
async function fetchJSON(u){ const r=await fetch(u,{cache:'no-store'}); if(!r.ok) throw new Error(r.status); return r.json(); }
function applyText(el, v, cls){ if(!el) return; const s=String(v ?? ''); if(el.textContent!==s){ el.textContent=s; if(cls){ el.classList.remove(cls); void el.offsetWidth; el.classList.add(cls); } } }
function setWon(a,b,t){ return Math.max(a,b) >= t && Math.abs(a-b) >= 2; }
function cleanName(n){ return (n||"").replace(/\s*\(.*?\)\s*/g," ").replace(/\s{2,}/g," ").trim(); }

/* chips (no animation) */
function completedSetLines(A,B){
  const a1=A.game1||0,b1=B.game1||0, a2=A.game2||0,b2=B.game2||0, a3=A.game3||0,b3=B.game3||0;
  const out=[]; if(setWon(a1,b1,21)) out.push(`${a1}-${b1}`); if(setWon(a2,b2,21)) out.push(`${a2}-${b2}`); if(setWon(a3,b3,15)) out.push(`${a3}-${b3}`);
  return out;
}
function buildSetChips(lines){
  const host=document.getElementById('setsline'); if(!host) return;
  if(!lines || !lines.length){ host.style.display='none'; lastSetLinesKey=""; return; }
  const key = JSON.stringify(lines);
  if(key === lastSetLinesKey) return;
  host.innerHTML = lines.map((t,i)=>{ const [as,bs]=String(t).split('-'); const a=+as||0, b=+bs||0; const cls=(a>b?' a-win':'')+(b>a?' b-win':''); return `<div class="chip${cls}">S${i+1} <span class='a'>${a}</span>-<span class='b'>${b}</span></div>`; }).join('');
  host.style.display='';
  lastSetLinesKey = key;
}

/* renderer */
function applyVmixArray(vm){
  if(!Array.isArray(vm) || vm.length<2) return;
  const A=vm[0], B=vm[1];

  const nameOf = t => (t.teamName || t.name || '');
  applyText(document.getElementById('nameA'), cleanName(nameOf(A)) || 'Team A', 'fade');
  applyText(document.getElementById('nameB'), cleanName(nameOf(B)) || 'Team B', 'fade');

  const ga=[A.game1||0,A.game2||0,A.game3||0], gb=[B.game1||0,B.game2||0,B.game3||0];
  const w1=setWon(ga[0],gb[0],21), w2=setWon(ga[1],gb[1],21), w3=setWon(ga[2],gb[2],15);
  let idx=0; if(w1&&(ga[1]||gb[1])) idx=1; if(w1&&w2&&(ga[2]||gb[2])) idx=2;

  if(prev.set !== idx){ lastServer = null; prev.a = null; prev.b = null; prev.set = idx; }

  const pa=ga[idx]||0, pb=gb[idx]||0;
  applyText(document.getElementById('scoreA'), pa, 'flip');
  applyText(document.getElementById('scoreB'), pb, 'flip');

  const setsA=(w1&&ga[0]>gb[0]?1:0)+(w2&&ga[1]>gb[1]?1:0)+(w3&&ga[2]>gb[2]?1:0);
  const setsB=(w1&&gb[0]>ga[0]?1:0)+(w2&&gb[1]>ga[1]?1:0)+(w3&&gb[2]>ga[2]?1:0);
  applyText(document.getElementById('setsA'), `(${setsA})`, 'fade');
  applyText(document.getElementById('setsB'), `(${setsB})`, 'fade');

  buildSetChips(completedSetLines(A,B));

  const meta=document.getElementById('meta');
  const matchOver=(setsA===2||setsB===2)||w3;
  applyText(meta, matchOver ? 'Final' : `Set ${idx+1}`, 'fade');

  const sA=document.getElementById('serveA'), sB=document.getElementById('serveB');
  if(prev.a !== null && prev.b !== null){
    if(pa > prev.a)      lastServer = 'A';
    else if(pb > prev.b) lastServer = 'B';
  }
  if(lastServer === 'A'){ sA.classList.remove('off'); sB.classList.add('off'); }
  else if(lastServer === 'B'){ sB.classList.remove('off'); sA.classList.add('off'); }
  else { sA.classList.add('off'); sB.classList.add('off'); }

  prev.a = pa; prev.b = pb;
}

/* ticks */
async function tick(){ try{ const d=await fetchJSON(SRC); if(d) applyVmixArray(d); }catch(_){} finally{ setTimeout(tick,POLL_MS); } }

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
    const o = await fetchJSON(NEXT_SRC);
    const a = (o && typeof o.a === 'string') ? cleanName(o.a) : '';
    const b = (o && typeof o.b === 'string') ? cleanName(o.b) : '';
    const l = (o && typeof o.label === 'string') ? o.label.trim() : '';
    let label = 'Next: ';
    const names = (a && b) ? `${a} vs ${b}` : (a || b) ? `${a || b} vs TBD` : 'TBD vs TBD';
    label += names + (l ? `  •  ${l}` : '');
    applyText(document.getElementById('next'), label, 'fade');
  }catch(_){} finally{ setTimeout(tickNext, Math.max(POLL_MS*2, 1500)); }
}

tick();
tickLabel();
tickNext();
</script>
</body>
</html>
"""#
    
    // Capture the current next match info to freeze during hold period
    private func captureNextMatchForHold(courtId: Int, expires: Date) async {
        guard 
            let vm = self.appViewModel,
            let ci = vm.idxOf(courtId)
        else { return }
        
        let ai = (vm.courts[ci].activeIndex ?? -1)
        let ni = ai + 1
        guard ni < vm.courts[ci].queue.count else {
            // No next item, store empty state
            self.nextHolds[courtId] = (nextData: ["a": NSNull(), "b": NSNull(), "label": NSNull()], expires: expires)
            return
        }
        
        let url = vm.courts[ci].queue[ni].apiURL
        let nextLabel = vm.courts[ci].queue[ni].label
        
        // Helper to keep only the round/extra text (drop any "A vs B • " prefix)
        func roundOnly(_ raw: String?) -> String? {
            guard let s = raw else { return nil }
            let parts = s.components(separatedBy: " • ").dropFirst()
            let t = parts.joined(separator: " • ").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        
        let labelOut: Any = (roundOnly(nextLabel) as Any?) ?? NSNull()
        
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                // Couldn't fetch names; store only label
                self.nextHolds[courtId] = (nextData: ["a": NSNull(), "b": NSNull(), "label": labelOut], expires: expires)
                return
            }
            
            // Try to read A/B names from upstream JSON (supports both schemas)
            guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) else {
                self.nextHolds[courtId] = (nextData: ["a": NSNull(), "b": NSNull(), "label": labelOut], expires: expires)
                return
            }
            
            let (aName, bName) = Self.extractNames(from: obj)
            let aOut: Any = (aName?.isEmpty == false) ? aName! : NSNull()
            let bOut: Any = (bName?.isEmpty == false) ? bName! : NSNull()
            
            self.nextHolds[courtId] = (nextData: [
                "a": aOut,
                "b": bOut,
                "label": labelOut
            ], expires: expires)
        } catch {
            // On any error, still store label if we have it
            self.nextHolds[courtId] = (nextData: ["a": NSNull(), "b": NSNull(), "label": labelOut], expires: expires)
        }
    }
}



// MARK: - Small "safe" subscript for arrays (optional nicety)
private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
