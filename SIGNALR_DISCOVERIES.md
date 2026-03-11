# SignalR Integration — Discovery Notes

> **Date:** 2026-03-01
> **Branch:** `feature/signalr-integration`
> **Status:** Schema captured, Phase 2 ready to implement

---

## Key Discovery: Subscription Required

The VBL SignalR hub requires clients to explicitly subscribe to a tournament to receive `StoreMutation` messages. Without this step, the WebSocket connection stays open but receives **zero** score updates.

### Subscription Method

```
Client → Server: SubscribeToTournament(tournamentId, divisionId, loadOrder)
```

| Argument | Type | Description |
|----------|------|-------------|
| `tournamentId` | int | Tournament/event ID from the VBL URL (`/event/{id}`) |
| `divisionId` | int? | Division ID to filter updates (can be null for all divisions) |
| `loadOrder` | string? | Used for incremental updates, typically `null` for initial subscription |

**Example:** For `https://volleyballlife.com/event/34785/division/127872/...`
```
SubscribeToTournament(34785, 127872, null)
```

### Unsubscription (note the typo — this is VBL's actual method name)

```
Client → Server: UnsubsribeToTournament(tournamentId)
```

### How the VBL Frontend Uses This

From decompiled `app.20202784.js`:
```javascript
// Vuex action dispatched when user navigates to a tournament page
subscribe({ tournamentId, divisionId, teamId, add }) {
    let loadOrder = add ? null : tournament.loadOrder || null;
    connection.invoke("SubscribeToTournament", tournamentId, divisionId, loadOrder);
}
```

The frontend also calls `_resubscribe()` on reconnect to re-join all active subscriptions.

---

## Captured Mutation Schema

### `UPDATE_GAME` — Score Updates

**Fired:** On every point change (each time a ref taps +1 in the VBL scoring interface).

**SignalR frame format:**
```json
{
    "type": 1,
    "target": "StoreMutation",
    "arguments": [
        "UPDATE_GAME",
        {
            "id": 4868943,
            "home": 25,
            "away": 12,
            "cap": 0,
            "isFinal": false,
            "number": 0,
            "to": 0,
            "_winner": null,
            "dtModified": "1772402850143"
        }
    ]
}
```

**Payload fields:**

| Field | Type | Description |
|-------|------|-------------|
| `id` | int | **Game ID** — uniquely identifies this set/game. Maps to `games[].id` in the hydrate response. |
| `home` | int | Current home team score (points in this game/set) |
| `away` | int | Current away team score |
| `cap` | int | Point cap (0 = no cap / win by 2) |
| `isFinal` | bool | Whether this game/set is complete |
| `number` | int | Game number (**0-indexed** in mutations, vs 1-indexed in vMix) |
| `to` | int | Points to win (always 0 in mutations — use hydrate data for this) |
| `_winner` | string? | `"home"` or `"away"` when final, `null` otherwise |
| `dtModified` | string | Epoch milliseconds as a string (for conflict resolution) |

### `UPDATE_DIVISION` — Division State

**Fired:** Immediately upon subscription. Contains the full division hydrate data.

This is the same payload as `GET /division/{id}/hydrate` — the entire division tree with days, brackets, pools, matches, teams, games, and scores.

**Usage:** Can be used to initialize/refresh the full match list without a separate HTTP call.

---

## Mapping Game ID → Court

The critical question for Phase 2: how to map an incoming `UPDATE_GAME` mutation to a specific court in the app.

**The chain:**
```
UPDATE_GAME.id (game ID: 4868943)
    ↓
hydrate response: match.games[].id == 4868943 → match ID 325751
    ↓
MatchItem.apiURL contains match ID: /matches/325751/vmix?bracket=true
    ↓
Court.queue[activeIndex].apiURL → court ID
```

**Solution:** Parse and store the match ID from `MatchItem.apiURL`, then build a `gameId → courtId` lookup from the hydrate data's `match.games[]` array.

**Important:** The game ID changes per set. Game 1 has ID `4868943`, Game 2 would have a different ID. The app needs to track ALL game IDs for the current match, not just game 1.

---

## All Known Hub Methods

### Server → Client

| Method | Args | Description |
|--------|------|-------------|
| `StoreMutation` | `(name: String, payload: Any)` | Vuex store mutation — score updates, division updates |
| `StoreAction` | `(name: String, payload: Any)` | Vuex store action dispatches |
| `NoUser` | `()` | User session expired, need to re-auth |
| `consoleLog` | `(msg: String)` | Debug log messages from server |

### Client → Server

| Method | Args | Description |
|--------|------|-------------|
| `SubscribeToTournament` | `(tournamentId, divisionId?, loadOrder?)` | **Subscribe to receive mutations** |
| `UnsubsribeToTournament` | `(tournamentId)` | Unsubscribe (note: typo is intentional, matches server) |
| `FetchAds` | `(subdomain: String)` | Fetch ad content |
| `AdClick` | `({id, page})` | Track ad click |
| `Lead` | `(data)` | Lead tracking |
| `PlayerSearch` | `(query: String)` | Player search |
| `GetBid` | `(dto)` | Get bid info |
| `CheckPass` | `({id, p})` | Check tournament pass |

---

## Phase 1 Validation Results (2026-03-01)

| Step | Status | Notes |
|------|--------|-------|
| Auth (`POST /account/login`) | ✅ 200 | JWT + 4 cookies |
| Negotiate (`POST /live/negotiate`) | ✅ 200 | Azure SignalR URL + access token |
| WebSocket to Azure SignalR | ✅ Connected | No proxy issues on this network |
| SignalR handshake | ✅ `{}` received | Protocol v1 JSON |
| Ping/pong | ✅ Working | 15s interval |
| SubscribeToTournament | ✅ Working | Receives `UPDATE_DIVISION` immediately |
| Score mutation capture | ✅ 6/6 captured | All `UPDATE_GAME` mutations received in real-time |
| Score update latency | ~instant | Mutations received within milliseconds of API call |

### Previous Blocker (Resolved)
McAfee Web Gateway on a different network was blocking WebSocket upgrades to `*.service.signalr.net`, returning an HTML 403 page. Testing on a clean network confirmed the code is correct.

---

## Implications for Phase 2 Implementation

1. **`VBLSignalRClient` needs `SubscribeToTournament`** — After handshake, must send this invocation with the tournament/division IDs for all active courts. Need to extract these IDs from `MatchItem` or hydrate data.

2. **Game ID mapping** — Store game IDs from hydrate data on `MatchItem` or `Court`. When `UPDATE_GAME` arrives, look up which court has that game ID active.

3. **Mutation is per-game, not per-match** — Each set/game in a match has its own ID. A best-of-3 match has 2-3 game IDs. Need to track all of them.

4. **`dtModified` for conflict resolution** — Use the epoch millis timestamp to determine which update is newer (SignalR vs polling).

5. **No match-level mutation** — Score updates are at the game (set) level. Match status (final, in progress) must be derived from the game data, similar to how polling works.

6. **Multiple divisions** — If courts span multiple divisions/tournaments, need multiple `SubscribeToTournament` calls.
