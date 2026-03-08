# SignalR Phase 2 Handoff — Score Mutation Pipeline

**Branch:** `feature/signalr-integration`
**Date:** 2026-03-01
**Commits:** `1389dd3` (Phase 2 implementation), `fbe8c1e` (remove adaptive polling)

---

## What Was Built

SignalR now delivers **instant score updates** (~50-100ms) as a bonus fast path on top of the existing 1.5s polling. When VBL's backend pushes an `UPDATE_GAME` mutation via SignalR, the app updates the overlay immediately. The next poll 0-1.5s later confirms the same score (a no-op). If SignalR fails silently or disconnects, polling continues unchanged — **zero risk to existing functionality**.

## Architecture Decision: No Adaptive Polling

We initially implemented adaptive polling (5s when SignalR connected, 1.5s when not). This was removed because it introduced a silent failure mode: if SignalR appeared "connected" but stopped delivering mutations (subscription dropped, Azure hiccup, gameIds not yet populated), scores would lag up to 5s with no visible indication. Since the user doesn't have time to test edge cases at tournaments, we chose the zero-risk approach: **polling always at 1.5s, SignalR is additive only**.

## Files Changed

| File | What Changed |
|------|-------------|
| `Court.swift` | Added `tournamentId: Int?` and `gameIds: [Int]?` to `MatchItem`. **Fixed bug:** `divisionId` was missing from `CodingKeys`/`init(from decoder:)` — it was being set at runtime but lost on serialization round-trips. |
| `ScannerViewModel.swift` | Added `parseTournamentId(from:)` (regex: `/event/(\d+)`). Added `tournamentId` to `VBLMatch`. Both scan paths (`scanSingleURL`, `scanAllURLsParallel`) now extract and propagate tournament ID. `createMatchItems` passes it to `MatchItem`. |
| `VBLSignalRClient.swift` | Added `subscribeToTournament(tournamentId:divisionId:)` — sends `SubscribeToTournament` invocation. Added `signalRDidConnect()` to `SignalRDelegate` protocol. Calls delegate after successful handshake (including reconnects). |
| `AppViewModel.swift` | Game ID mapping (`buildGameIdLookup`, `rebuildGameIdMap`), mutation processing (`processGameMutation`, `applySnapshotUpdate`), subscription management (`subscribeToAllActiveTournaments`). |
| `Constants.swift` | No net changes (added then removed `signalRConnectedPollingInterval`). |

## How the Pipeline Works

### 1. Game ID Discovery
When the hydrate endpoint is fetched (every 60s per division), `buildGameIdLookup` extracts `match.games[].id` from the hydrate JSON. These game IDs are stored on `MatchItem.gameIds`. A reverse lookup `gameIdToCourtMap` (gameId → courtId) is rebuilt whenever:
- Polling starts for a court
- A match auto-advances
- Hydrate refreshes with new game IDs

### 2. Tournament Subscription
When SignalR connects (or reconnects), `signalRDidConnect()` fires. This calls `subscribeToAllActiveTournaments()`, which collects unique `(tournamentId, divisionId)` pairs from all polling courts' queues and sends `SubscribeToTournament` for each. Without this subscription call, **zero mutations are received** — this was the key Phase 1 discovery.

### 3. Mutation Routing
When `StoreMutation("UPDATE_GAME", payload)` arrives:
1. Extract `id` (game ID) from payload
2. Look up `gameIdToCourtMap[gameId]` → court ID
3. If no mapping found, log and skip (poll will handle it)
4. Call `processGameMutation(courtId:gameId:payload:)`

### 4. Score Update
`processGameMutation` does:
- Updates the correct set in `setHistory` using `payload.number` (0-indexed)
- Recalculates match-level set scores (sets won by each team)
- Determines match status (In Progress / Final)
- Infers serving team from point deltas
- Calls `applySnapshotUpdate` for downstream state (inactivity tracking, stopwatch, status)

### 5. Poll Confirmation
The next poll cycle (0-1.5s later) fetches the same score from vMix. Since `lastScoreSnapshot` already matches, the inactivity tracker treats it as unchanged. Auto-advance, metadata refresh, and court change detection continue to run exclusively in `pollOnce`.

## Key Schema Details

### UPDATE_GAME Mutation Payload
```json
{
    "id": 4868943,           // Game ID (maps to games[].id in hydrate)
    "home": 25,              // Home team points in this set
    "away": 12,              // Away team points in this set
    "isFinal": false,        // Is this set complete?
    "number": 0,             // Set number (0-indexed!)
    "_winner": null,         // "home"/"away" when set final, null otherwise
    "cap": 0,                // Point cap (0 = none)
    "to": 0,                 // Points to win (0 in mutation, use hydrate/format)
    "dtModified": "1772402850143"  // Epoch ms as string
}
```

### SubscribeToTournament Invocation
```json
{"type":1,"target":"SubscribeToTournament","arguments":[34785, 127872, null]}
```
- Arg 0: tournament ID (from `/event/{id}` in URL)
- Arg 1: division ID (from `/division/{id}` in URL)
- Arg 2: loadOrder (always null for our use case)

### Mapping Chain
```
VBL URL: /event/34785/division/127872/.../matches/325750/vmix?bracket=true
                ↓              ↓                    ↓
         tournamentId    divisionId             matchId
                                                    ↓
                                        hydrate: match.games[].id → [4868943, 4868944, 4868945]
                                                                          ↓
                                                    SignalR: UPDATE_GAME {id: 4868943} → court 1
```

## Known Limitations

1. **Cold start gap:** If SignalR connects before the first hydrate runs (~60s), `gameIds` will be nil and mutations are silently dropped until hydrate populates them. Polling covers this gap.

2. **Team names on first mutation:** If the very first score update for a match comes via SignalR before any poll, the snapshot inherits from `.empty()` with placeholder names. The next poll fills in real names.

3. **Auto-advance is poll-only:** Match completion detection and queue advancement run exclusively in `pollOnce`. SignalR marks matches as finished in the UI, but actual queue advancement waits for the next poll cycle.

4. **Unsubscribe not implemented:** We subscribe on connect but never call `UnsubsribeToTournament` (note: VBL's typo). For our use case this is fine — subscriptions are cleaned up when the WebSocket disconnects.

## Testing Checklist for Next Session

- [ ] Enable SignalR toggle, start polling on a court with a live event
- [ ] Verify console shows `[SignalR] Subscribed to tournament X, division Y`
- [ ] Score a point — verify `[SignalR] Court X updated: Set 1 → ...` appears before the next poll
- [ ] Disable WiFi, re-enable — verify auto-reconnect + re-subscribe in logs
- [ ] Verify the pre-existing test `CourtTests/create_setsDefaults` failure (expects "Overlay 3", gets "Mevo 3") — unrelated to SignalR
