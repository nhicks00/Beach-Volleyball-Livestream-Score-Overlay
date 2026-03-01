# SignalR Integration — Phase 2: Wire Score Mutations into Scoring Pipeline

## Prerequisites

Phase 1 must be complete and validated:
- [x] `VBLSignalRClient` connects, authenticates, negotiates, and establishes WebSocket
- [ ] WebSocket handshake succeeds on a clean network (Phase 1 testing)
- [ ] `StoreMutation` messages are being received and logged
- [ ] **Payload schema is documented** — we need to know the exact JSON structure of score-related mutations before implementing Phase 2

---

## The Goal

Replace (or supplement) the 1.5s polling loop with instant score updates from SignalR. When a ref taps a score button on VBL, the app should update the overlay within milliseconds instead of up to 1.5 seconds.

**Hybrid approach:** SignalR provides instant updates; polling remains as a fallback for resilience. If SignalR disconnects, polling continues seamlessly. If SignalR is connected, we can optionally reduce polling frequency (e.g., every 10s instead of 1.5s) to just serve as a consistency check.

---

## What We Need to Discover First (Phase 1 Output)

Before writing any Phase 2 code, we need to capture and document the actual `StoreMutation` payloads during a live event. Key questions:

1. **What mutation names carry score data?** (e.g., `"SET_MATCH_SCORE"`, `"UPDATE_GAME"`, etc.)
2. **What's in the payload?** We need:
   - Match ID (to map to a court)
   - Current game/set scores (home and away points)
   - Set number or game number
   - Match status (in progress, final, etc.)
   - Team identifiers (to confirm correct match mapping)
3. **Are there separate mutations for:** point scored, set complete, match complete? Or one mutation with the full state?
4. **What's the match ID format?** Is it the same `bracketMatchId` from the hydrate API, the vMix match ID, or something else?
5. **How often do mutations fire?** One per point? One per state change?

### How to Capture This

During Phase 1 testing on a clean network with a live event:
1. Enable SignalR in the app
2. Open Settings > Logs tab
3. Watch for `[SignalR] StoreMutation` entries
4. **Document every unique mutation name and its payload structure**
5. Save representative samples in a file (or paste them into this doc)

**Paste captured mutation samples here once available:**

```
(mutations will be documented here during Phase 1 testing)
```

---

## Architecture Plan

### Current Scoring Pipeline (polling)

```
Timer (1.5s) → pollOnce(courtId)
  → scoreCache.get(matchItem.apiURL)          // HTTP GET to vMix endpoint
  → normalizeData(data)                       // Parse vMix JSON → ScoreSnapshot
  → inactivity/stale checks
  → status determination
  → webSocketHub.broadcastScoreUpdate()       // Push to OBS overlays
  → saveConfiguration()
```

Key types:
- **`ScoreSnapshot`** — The normalized score state (team names, set scores, set history, status, serve)
- **`SetScore`** — Per-set scores (setNumber, team1Score, team2Score, isComplete)
- **`MatchItem`** — Queue entry with `apiURL`, team names, format info, `divisionId`
- **`normalizeData()`** in `AppViewModel` — Converts raw vMix JSON into `ScoreSnapshot`
- **`normalizeArrayFormat()`** — Handles the vMix array format `[{team1}, {team2}]`

### Proposed Phase 2 Pipeline (SignalR + polling)

```
VBLSignalRClient receives StoreMutation
  → delegate.signalRDidReceiveMutation(name, payload)
  → AppViewModel.processScoreMutation(name, payload)
      → Map mutation to court (via match ID → MatchItem lookup)
      → Parse mutation payload → ScoreSnapshot
      → Run same downstream logic: status, inactivity, broadcast, save

Timer (10s, reduced) → pollOnce(courtId)     // Consistency fallback
  → Same as before, but less frequent
```

---

## Implementation Steps (once schema is known)

### Step 1: Match ID → Court Mapping

We need to map incoming mutation match IDs to active courts. Add to `AppViewModel`:

```swift
/// Map a match identifier from SignalR to the court currently playing it.
/// Returns (courtId, queueIndex) or nil if no court has this match active.
private func courtForMatch(id: Int) -> (courtId: Int, queueIndex: Int)? {
    for court in courts {
        guard let activeIdx = court.activeIndex,
              activeIdx < court.queue.count else { continue }
        let match = court.queue[activeIdx]
        // Compare against whatever ID field the mutation uses
        // This might be: match.apiURL path component, match.matchNumber, etc.
        // TBD based on mutation payload schema
        if matchIdMatches(match, mutationId: id) {
            return (court.id, activeIdx)
        }
    }
    return nil
}
```

**Open question:** What identifier does the mutation use? We need to map it to `MatchItem.apiURL` or extract a match ID from the vMix URL path. The vMix URL format is `api.volleyballlife.com/api/v1.0/matches/{id}/vmix?bracket=true|false` — the `{id}` in the URL is likely the same ID in the mutation. Consider storing a parsed `matchId: Int?` on `MatchItem` during import.

### Step 2: Mutation → ScoreSnapshot Parser

Create a new method that converts the SignalR mutation payload into a `ScoreSnapshot`, similar to how `normalizeArrayFormat()` converts vMix data:

```swift
/// Convert a SignalR StoreMutation payload into a ScoreSnapshot.
/// Schema TBD — this is a placeholder until we capture real payloads.
private func snapshotFromMutation(
    _ payload: [String: Any],
    courtId: Int,
    currentMatch: MatchItem
) -> ScoreSnapshot? {
    // Extract scores, set info, status from the mutation payload
    // Map to ScoreSnapshot fields
    // Return nil if the mutation doesn't contain score data
}
```

### Step 3: Wire Delegate into Scoring Pipeline

Replace the Phase 1 log-only delegate method with real processing:

```swift
func signalRDidReceiveMutation(name: String, payload: Any) {
    // Still log for debugging
    scannerViewModel.addSignalRLog("[SignalR] '\(name)': ...")

    // Only process score-related mutations
    guard isScoreMutation(name) else { return }
    guard let dict = payload as? [String: Any] else { return }

    // Map to court
    guard let matchId = extractMatchId(from: dict),
          let (courtId, _) = courtForMatch(id: matchId),
          let idx = courtIndex(for: courtId) else { return }

    let matchItem = courts[idx].queue[courts[idx].activeIndex!]

    // Parse into snapshot
    guard let snapshot = snapshotFromMutation(dict, courtId: courtId, currentMatch: matchItem) else { return }

    // Run the same downstream logic as pollOnce()
    processScoreUpdate(snapshot, for: courtId)
}
```

### Step 4: Extract Common Score Processing

Refactor the score processing logic out of `pollOnce()` into a shared method that both polling and SignalR can use:

```swift
/// Process a score update from any source (polling or SignalR).
private func processScoreUpdate(_ snapshot: ScoreSnapshot, for courtId: Int) {
    // Inactivity tracking
    // Status determination
    // Match completion detection
    // Overlay broadcast
    // Save configuration
    // (All the logic currently in pollOnce() after normalizeData())
}
```

Then `pollOnce()` calls `processScoreUpdate(normalizeData(data), for: courtId)` and the SignalR delegate calls `processScoreUpdate(snapshotFromMutation(...), for: courtId)`.

### Step 5: Adaptive Polling

When SignalR is connected, reduce polling frequency as a consistency check rather than the primary data source:

```swift
private var signalRConnectedPollingInterval: TimeInterval { 10.0 }  // fallback check

// In startPolling(), use different interval based on SignalR status
let interval = (signalRStatus == .connected)
    ? signalRConnectedPollingInterval
    : appSettings.pollingInterval
```

When SignalR disconnects, automatically resume fast polling. When it reconnects, slow polling back down.

### Step 6: Score Conflict Resolution

If both SignalR and polling deliver updates, we need a simple conflict resolution:

- **SignalR wins if more recent** — Compare timestamps; SignalR updates should always be newer
- **Polling serves as correction** — If polling shows a different score than the last SignalR update, the polling data takes precedence (it's the ground truth from the vMix endpoint)
- **Never go backwards** — If SignalR shows a higher score than polling, keep the higher score (the poll might be stale from cache)

### Step 7: UI Enhancements

- Show "via SignalR" or "via poll" indicator on court cards (optional, for debugging)
- Add a mutation count to the SignalR status pill: `"Connected (142 msgs)"`
- Consider a Settings option: "Reduce polling when SignalR active"

### Step 8: Tests

- Unit test: mutation payload → ScoreSnapshot conversion
- Unit test: match ID → court mapping
- Unit test: conflict resolution (SignalR vs polling)
- Unit test: adaptive polling interval changes with connection status
- Integration test: mock SignalR mutations flow through to overlay broadcast

---

## Files to Modify (Phase 2)

| File | Changes |
|------|---------|
| `VBLSignalRClient.swift` | Minimal — maybe add mutation filtering |
| `AppViewModel.swift` | Major — mutation processing, match mapping, refactored `processScoreUpdate()`, adaptive polling |
| `Court.swift` / `MatchItem` | Add `matchId: Int?` field for direct ID matching |
| `DashboardView.swift` | Optional — SignalR indicator on court cards |
| `Constants.swift` | Add `signalRConnectedPollingInterval` |
| Tests | New test file for Phase 2 mutation parsing |

---

## Risk Mitigation

1. **SignalR is additive, not replacing.** Polling always runs as fallback. If SignalR breaks, nothing changes for the user.
2. **Feature-flagged.** The `signalREnabled` toggle keeps this entirely opt-in. Ship it disabled by default.
3. **Schema changes.** If VBL changes their mutation format, worst case SignalR stops working and polling takes over. Add version/schema detection to log warnings.
4. **Rate limiting.** If mutations fire too fast (e.g., rapid score corrections), debounce updates to avoid overlay flickering. A 100ms debounce window should be sufficient.

---

## Big Picture / End State

Once Phase 2 is complete, the scoring pipeline becomes:

- **Primary:** SignalR push (instant, ~0ms latency)
- **Secondary:** Polling every 10s (consistency check, catches anything SignalR missed)
- **Fallback:** If SignalR disconnects, polling auto-resumes at 1.5s until reconnected

This gives us the best of both worlds — instant updates when available, bulletproof reliability from polling, zero manual intervention needed.
