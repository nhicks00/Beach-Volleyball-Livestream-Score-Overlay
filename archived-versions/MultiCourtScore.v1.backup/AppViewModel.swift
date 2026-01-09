import Foundation
import Combine

final class AppViewModel: ObservableObject {
    @Published var courts: [Court] = []
    @Published var vblBridge = VBLPythonBridge()
    
    private var timers: [Int: Timer] = [:]
    private let wsHub = WebSocketHub.shared
    
    // MARK: - Init / Persistence
    init(defaultCount: Int = 10) {
        if !loadConfig() {
            self.courts = (1...defaultCount).map {
                Court(id: $0, name: "Court \($0)", queue: [], activeIndex: nil, status: .idle, lastSnapshot: nil, liveSince: nil)
            }
        }
    }
    
    func startServices() {
        wsHub.start(with: self)
    }
    
    private var configURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("MultiCourtScoreConfig.json")
    }
    
    @discardableResult
    private func loadConfig() -> Bool {
        guard let data = try? Data(contentsOf: configURL),
              let saved = try? JSONDecoder().decode([Court].self, from: data) else { return false }
        self.courts = saved
        return true
    }
    
    private func saveConfig() {
        if let data = try? JSONEncoder().encode(courts) {
            try? data.write(to: configURL)
        }
    }
    
    /// Checks if a match has started based on its API data.
    private func nextHasStarted(from data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) else { return false }
        
        // vMix array format
        if let arr = obj as? [[String: Any]], arr.count >= 2 {
            let a = arr[0], b = arr[1]
            let g1a = (a["game1"] as? Int) ?? 0
            let g1b = (b["game1"] as? Int) ?? 0
            return (g1a + g1b) > 0
        }
        
        // Dictionary format
        if let dict = obj as? [String: Any] {
            let s = dict["score"] as? [String: Any]
            let t1 = (dict["team1Score"] ?? dict["homeScore"] ?? s?["home"]) as? Int ?? 0
            let t2 = (dict["team2Score"] ?? dict["awayScore"] ?? s?["away"]) as? Int ?? 0
            return (t1 + t2) > 0
        }
        
        return false
    }
    
    // MARK: - Court Management
    func addCourt(withId specificId: Int? = nil) {
        let nextId: Int
        if let specificId = specificId {
            // Use the specified ID if it's not already taken
            let existingIds = Set(courts.map { $0.id })
            if existingIds.contains(specificId) {
                // If specified ID is taken, find the first available ID starting from 1
                nextId = findNextAvailableId()
            } else {
                nextId = specificId
            }
        } else {
            // Find the first available ID starting from 1
            nextId = findNextAvailableId()
        }
        courts.append(Court(id: nextId, name: "Court \(nextId)", queue: [], activeIndex: nil, status: .idle, lastSnapshot: nil, liveSince: nil))
        saveConfig()
    }
    
    private func findNextAvailableId() -> Int {
        let existingIds = Set(courts.map { $0.id })
        var nextId = 1
        while existingIds.contains(nextId) {
            nextId += 1
        }
        return nextId
    }
    
    func removeCourt(_ courtId: Int) {
        stop(courtId)
        courts.removeAll { $0.id == courtId }
        saveConfig()
    }
    
    func renameCourt(_ courtId: Int, to newName: String) {
        updateCourt(courtId) { $0.name = newName }
    }
    
    func replaceQueue(_ courtId: Int, with items: [MatchItem]) {
        updateCourt(courtId) { c in
            c.queue = items
            c.activeIndex = items.isEmpty ? nil : 0
            c.status = items.isEmpty ? .idle : .waiting
            c.lastSnapshot = nil
            c.liveSince = nil
        }
    }
    
    func clearQueue(_ courtId: Int) {
        updateCourt(courtId) { c in
            c.queue.removeAll()
            c.activeIndex = nil
            c.status = .idle
            c.lastSnapshot = nil
            c.liveSince = nil
        }
    }
    
    // MARK: - Global Controls
    func startAll() { courts.forEach { run($0.id) } }
    func stopAll()  { courts.forEach { stop($0.id) } }
    func clearAllQueues() { courts.forEach { clearQueue($0.id) } }
    
    // MARK: - VBL Integration
    func scanVBLBracket(url: String, username: String? = nil, password: String? = nil) {
        vblBridge.scanBracket(url: url, username: username, password: password)
    }
    
    func populateCourtFromVBL(courtId: Int, matches: [VBLPythonBridge.VBLMatchData]) {
        let matchItems = vblBridge.createMatchItems(from: matches)
        replaceQueue(courtId, with: matchItems)
    }
    
    // MARK: - Per-Court Controls
    func run(_ courtId: Int) {
        guard let idx = idxOf(courtId) else { return }
        if courts[idx].activeIndex == nil { courts[idx].activeIndex = 0 }
        courts[idx].status = .waiting
        startPolling(courtId)
        saveConfig()
    }
    
    func stop(_ courtId: Int) {
        timers[courtId]?.invalidate()
        timers[courtId] = nil
        updateCourt(courtId) {
            $0.status = .idle
            $0.liveSince = nil
        }
    }
    
    func skip(_ courtId: Int) {
        updateCourt(courtId) { c in
            guard let ai = c.activeIndex else { return }
            let next = ai + 1
            if next < c.queue.count {
                c.activeIndex = next
                c.status = .waiting
                c.liveSince = nil
                c.lastSnapshot = nil
            }
        }
    }
    
    func skipToPrevious(_ courtId: Int) {
        updateCourt(courtId) { c in
            guard let ai = c.activeIndex else { return }
            let previous = ai - 1
            if previous >= 0 {
                c.activeIndex = previous
                c.status = .waiting
                c.liveSince = nil
                c.lastSnapshot = nil
            }
        }
    }
    
    // MARK: - Polling Logic
    private func startPolling(_ courtId: Int) {
        timers[courtId]?.invalidate()

        let jitter = Double((courtId * 317) % 1200) / 1000.0
        let interval = 2.5 + Double((courtId * 97) % 800) / 1000.0

        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task {
                try? await Task.sleep(nanoseconds: UInt64(jitter * 1_000_000_000))
                await self?.pollOnce(courtId)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timers[courtId] = t
    }
    
    @MainActor
    private func pollOnce(_ courtId: Int) async {
        guard let ci = idxOf(courtId), courts[ci].status != .idle else {
            stop(courtId)
            return
        }
        guard let ai = courts[ci].activeIndex, ai < courts[ci].queue.count else { return }
        
        let item = courts[ci].queue[ai]
        
        do {
            let (data, _) = try await URLSession.shared.data(from: item.apiURL)
            OverlayStore.shared.setRaw(courtId: courtId, data: data)
            
            let snap = normalizeData(data, courtId: courtId)
            let before = courts[ci].status
            let upper = snap.status.uppercased()
            let status: CourtStatus = (["LIVE", "IN_PROGRESS"].contains(upper) ? .live :
                                        ["FINAL", "FINISHED", "COMPLETE"].contains(upper) ? .finished : .waiting)
            
            // Stopwatch handling
            if before != .live && status == .live { courts[ci].liveSince = Date() }
            if status != .live { courts[ci].liveSince = nil }
            
            // Logic to auto-advance to the next match
            if status == .finished {
                courts[ci].status = .finished
                courts[ci].lastSnapshot = snap
                
                let nextIndex = ai + 1
                if nextIndex < courts[ci].queue.count {
                    let nextItem = courts[ci].queue[nextIndex]
                    do {
                        let (probeData, _) = try await URLSession.shared.data(from: nextItem.apiURL)
                        if nextHasStarted(from: probeData) {
                            courts[ci].activeIndex = nextIndex
                            courts[ci].status = .waiting
                            courts[ci].lastSnapshot = nil
                            courts[ci].liveSince = nil
                        }
                    } catch {
                        // Ignore probe errors, will try again next tick
                    }
                }
                saveConfig()
                return
            }
            
            courts[ci].status = status
            courts[ci].lastSnapshot = snap
            saveConfig()
            
        } catch {
            courts[ci].status = .error
        }
    }
    
    // MARK: - Data Normalization
    private func normalizeData(_ data: Data, courtId: Int) -> ScoreSnapshot {
        guard let jsonObj = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return ScoreSnapshot.empty(courtId: courtId)
        }
        
        if let arr = jsonObj as? [[String: Any]] {
            return normalizeArray(rawArray: arr, courtId: courtId)
        } else if let dict = jsonObj as? [String: Any] {
            return normalizeDict(raw: dict, courtId: courtId)
        }
        return ScoreSnapshot.empty(courtId: courtId)
    }
    
    private func normalizeArray(rawArray: [[String: Any]], courtId: Int) -> ScoreSnapshot {
        let t1 = rawArray.indices.contains(0) ? rawArray[0] : [:]
        let t2 = rawArray.indices.contains(1) ? rawArray[1] : [:]
        let name1 = (t1["teamName"] as? String) ?? "Team A"
        let name2 = (t2["teamName"] as? String) ?? "Team B"
        let g1a = (t1["game1"] as? Int) ?? 0, g1b = (t2["game1"] as? Int) ?? 0
        let g2a = (t1["game2"] as? Int) ?? 0, g2b = (t2["game2"] as? Int) ?? 0
        let g3a = (t1["game3"] as? Int) ?? 0, g3b = (t2["game3"] as? Int) ?? 0
        
        func won(_ a: Int, _ b: Int, _ t: Int) -> Bool { max(a, b) >= t && abs(a - b) >= 2 }
        let won1 = won(g1a, g1b, 21), won2 = won(g2a, g2b, 21), won3 = won(g3a, g3b, 15)
        
        let idx: Int = (won1 && won2) ? 2 : (won1 ? 1 : 0)
        let curA = [g1a, g2a, g3a][idx], curB = [g1b, g2b, g3b][idx]
        
        let setsWonA = (won1 && g1a > g1b ? 1 : 0) + (won2 && g2a > g2b ? 1 : 0)
        let setsWonB = (won1 && g1b > g1a ? 1 : 0) + (won2 && g2b > g2a ? 1 : 0)
        let finished = (setsWonA >= 2 || setsWonB >= 2) || won3
        let status = finished ? "FINAL" : ((g1a + g1b + g2a + g2b + g3a + g3b) > 0 ? "LIVE" : "WAITING")
        
        // Build set history
        var setHistory: [SetScore] = []
        if g1a > 0 || g1b > 0 {
            setHistory.append(SetScore(setNumber: 1, team1Score: g1a, team2Score: g1b, isComplete: won1))
        }
        if g2a > 0 || g2b > 0 {
            setHistory.append(SetScore(setNumber: 2, team1Score: g2a, team2Score: g2b, isComplete: won2))
        }
        if g3a > 0 || g3b > 0 {
            setHistory.append(SetScore(setNumber: 3, team1Score: g3a, team2Score: g3b, isComplete: won3))
        }
        
        return ScoreSnapshot(court: courtId, matchId: nil, status: status, setNumber: idx + 1,
                             team1Name: name1, team2Name: name2, team1Score: curA, team2Score: curB, serve: nil, setHistory: setHistory)
    }
    
    private func normalizeDict(raw: [String: Any], courtId: Int) -> ScoreSnapshot {
        let t1 = (raw["homeTeamName"] ?? raw["team1Name"] ?? (raw["home"] as? [String: Any])?["name"]) as? String ?? "Team A"
        let t2 = (raw["awayTeamName"] ?? raw["team2Name"] ?? (raw["away"] as? [String: Any])?["name"]) as? String ?? "Team B"
        let s1 = (raw["homeScore"] ?? raw["team1Score"] ?? (raw["score"] as? [String: Any])?["home"]) as? Int ?? 0
        let s2 = (raw["awayScore"] ?? raw["team2Score"] ?? (raw["score"] as? [String: Any])?["away"]) as? Int ?? 0
        let setNum = (raw["setNumber"] ?? raw["currentSet"]) as? Int ?? 1
        let status = (raw["status"] as? String) ?? ((s1 == 0 && s2 == 0) ? "WAITING" : "LIVE")
        let matchId = raw["matchId"] as? Int
        return ScoreSnapshot(court: courtId, matchId: matchId, status: status, setNumber: setNum,
                             team1Name: t1, team2Name: t2, team1Score: s1, team2Score: s2, serve: nil, setHistory: [])
    }
    
    // MARK: - Helpers
    private func updateCourt(_ courtId: Int, mutate: (inout Court) -> Void) {
        if let i = idxOf(courtId) {
            var c = courts[i]; mutate(&c); courts[i] = c
            saveConfig()
        }
    }
    
    func idxOf(_ courtId: Int) -> Int? {
        courts.firstIndex(where: { $0.id == courtId })
    }
    
    func overlayURL(for courtId: Int, pollMS: Int = 1000) -> String {
        "http://127.0.0.1:8787/overlay/court/\(courtId)/?poll=\(pollMS)"
    }
    
    // Populate team names for a match item by fetching from its API URL
    func populateTeamNames(for matchItem: inout MatchItem) async {
        guard matchItem.team1Name == nil || matchItem.team2Name == nil else { return }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: matchItem.apiURL)
            let snapshot = normalizeData(data, courtId: 0) // courtId not used for team names
            matchItem.team1Name = snapshot.team1Name
            matchItem.team2Name = snapshot.team2Name
        } catch {
            // If we can't fetch team names, keep existing values
        }
    }
}

extension ScoreSnapshot {
    static func empty(courtId: Int) -> ScoreSnapshot {
        ScoreSnapshot(court: courtId, matchId: nil, status: "WAITING", setNumber: 1,
                      team1Name: "Team A", team2Name: "Team B", team1Score: 0, team2Score: 0, serve: nil, setHistory: [])
    }
}
