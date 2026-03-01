# VolleyballLife (VBL) API Reference

> **Status:** Reverse-engineered from the VBL Vue.js frontend (`volleyballlife-web.azurewebsites.net`).
> VBL has no public documentation for this API. This was discovered by analyzing the
> minified JS bundle (`app.20202784.js`) and tracing service classes through Vue
> components, Vuex stores, and HTTP call sites.
>
> **Last verified:** 2026-03-01

---

## Table of Contents

1. [Overview](#overview)
2. [Authentication](#authentication)
3. [API Base URLs](#api-base-urls)
4. [Reading Match Data](#reading-match-data)
   - [URL Parsing: Website URL → API Call](#url-parsing-website-url--api-call)
   - [Division Hydrate](#division-hydrate)
   - [Hydrate Response Structure](#hydrate-response-structure)
   - [vMix Endpoint (Live Score Polling)](#vmix-endpoint-live-score-polling)
   - [Match Format Settings](#match-format-settings)
   - [Match Settings Endpoint](#match-settings-endpoint)
5. [Scoring Lifecycle](#scoring-lifecycle)
6. [Scoring Endpoints](#scoring-endpoints)
   - [Start Scoring Session](#1-start-scoring-session)
   - [Update Score](#2-update-score)
   - [Save Match Data](#3-save-match-data)
   - [Check Key Validity](#4-check-key-validity)
   - [End Scoring Session](#5-end-scoring-session)
7. [Data Models](#data-models)
   - [liveStartDto (Match Start DTO)](#livestartdto)
   - [Game DTO](#game-dto)
   - [Full Match DTO](#full-match-dto)
   - [Team Entry DTO](#team-entry-dto)
   - [VBLMatch (Scraper Output)](#vblmatch-scraper-output)
8. [SignalR Live Updates](#signalr-live-updates)
9. [Important Concepts](#important-concepts)
10. [Complete Working Example](#complete-working-example)
11. [Endpoint Discovery Map](#endpoint-discovery-map)

---

## Overview

The VBL scoring system works in three phases:

1. **Start** — Call the Start API with match data to create a scoring session. The server returns a `key` (UUID) that authenticates all subsequent scoring actions. For bracket matches, this is when the match record is actually created in the database (bracket matches are "virtual" until started).

2. **Score** — Use the Update endpoint with the scoring key to change game scores point-by-point. Use the Save Match endpoint to persist full match state (game completions, set transitions, etc.).

3. **End** — Call the End endpoint to close the scoring session and release the key.

The VBL frontend (`volleyballlife.com`) is a Vue.js SPA. The scoring functionality lives in a lazy-loaded component (`LiveScoring`) that uses a service class called `liveScoring` on the `$VBL` API object. The scoring service has four methods: `start`, `update`, `keycheck`, and `end`.

---

## Authentication

### Login

```
POST /account/login
Content-Type: application/json

{
    "username": "user@example.com",
    "password": "password"
}
```

**Response (200):**
```json
{
    "access_token": "<JWT>",
    "data": {
        "id": 3538,
        "userName": "user@example.com",
        "firstName": "Nathan",
        "lastName": "Hicks",
        "pages": [
            {"id": 875, "name": "ATX Beach", "role": "Admin", ...}
        ],
        "profiles": [...],
        ...
    }
}
```

**Response Headers (important):**
```
Set-Cookie: .AspNetCore.Identity.Application=<cookie_value>
Set-Cookie: ARRAffinity=<cookie_value>
Set-Cookie: ARRAffinitySameSite=<cookie_value>
```

### Using Auth on Subsequent Requests

All scoring endpoints require:
- `Authorization: Bearer <access_token>` header
- Cookies from the login response (especially `.AspNetCore.Identity.Application`)

### Required Headers (All Requests)

```
Accept: application/json
Content-Type: application/json
User-Agent: Mozilla/5.0
Referer: https://volleyballlife.com/
Origin: https://volleyballlife.com
Authorization: Bearer <access_token>
Cookie: <all_cookies_from_login>
```

> **Note:** The `Origin` and `Referer` headers are checked by the server's CORS policy. The response includes `Access-Control-Allow-Origin: https://volleyballlife.com`.

---

## API Base URLs

There are two API base URLs:

```
# Primary backend (ASP.NET Core 8 on Azure App Service)
https://volleyballlife-api-dot-net-8.azurewebsites.net

# vMix/overlay API (public-facing, different domain)
https://api.volleyballlife.com/api/v1.0/matches
```

- The **backend URL** is used for authentication, division hydrate, scoring, and all write operations.
- The **vMix URL** is used for live score polling by OBS/vMix overlays. It proxies to the same backend but through a different domain.
- SSL certificate verification may fail on some systems — use unverified SSL as a fallback if needed.

> **DNS Note:** The domain `volleyballlife.com` may not resolve on all networks. The Azure backend URL above is the direct endpoint and is more reliably reachable.

---

## Reading Match Data

### URL Parsing: Website URL → API Call

VBL website URLs follow this pattern:

```
https://{subdomain}.volleyballlife.com/event/{tournId}/division/{divId}/round/{dayId}/brackets
https://{subdomain}.volleyballlife.com/event/{tournId}/division/{divId}/round/{dayId}/pools/{poolId}
https://{subdomain}.volleyballlife.com/event/{tournId}/division/{divId}/round/{dayId}/pools
```

The **only required segment** is `/division/{divId}` — this maps directly to the hydrate API call.

**Parsing logic:**

| URL Segment | Extracted Value | Required? |
|-------------|----------------|-----------|
| `/event/{id}` | Tournament ID | No |
| `/division/{id}` | Division ID | **Yes** (without this, the URL is invalid) |
| `/round/{id}` | Day/Round ID | No (used to filter results) |
| `/pools/{id}` | Pool ID filter | No (when present, only that pool's matches are returned) |

**Type detection:**

| URL contains | Match type |
|-------------|------------|
| `bracket` or `playoff` (case-insensitive) | Bracket Play |
| `pool` (case-insensitive) | Pool Play |
| Neither | Both bracket and pool matches returned |

**Example:**
```
URL: https://norcalbeach.volleyballlife.com/event/34785/division/127872/round/261836/brackets
→ Division ID: 127872
→ Day ID: 261836
→ Type: Bracket Play
→ API Call: GET /division/127872/hydrate
```

### Division Hydrate

The primary endpoint for reading all match data for a division. This is the **only** read endpoint needed — one call returns everything.

```
GET /division/{divisionId}/hydrate
```

**No auth required** (public endpoint).

Returns the complete division tree: days, brackets, pools, matches, teams, games, scores, and format settings. The response is then filtered client-side by day ID, match type (bracket/pool), and pool ID.

### Hydrate Response Structure

The hydrate response contains two different structures depending on whether a day has bracket play or pool play.

```json
{
    "id": 127872,
    "teams": [
        {
            "id": 851171,
            "name": "Nathan Hicks / Reid Malone",
            "seed": 3,
            "players": [{"name": "Nathan Hicks"}, {"name": "Reid Malone"}]
        }
    ],
    "days": [
        {
            "id": 261836,
            "name": "Playoffs",
            "bracketPlay": true,
            "poolPlay": false,
            "brackets": [
                {
                    "id": 56262,
                    "name": "Playoffs",
                    "type": "SINGLE_ELIM",
                    "winnersMatchSettings": {
                        "gameSettings": [
                            {"to": 28, "cap": null, "number": 1}
                        ]
                    },
                    "matches": [
                        {
                            "id": 325751,
                            "displayNumber": 2,
                            "number": 126,
                            "court": 1,
                            "startTime": "2026-01-09T09:30:00.000Z",
                            "isBye": false,
                            "isWinners": true,
                            "round": 0,
                            "homeTeam": {"teamId": 851171, "seed": 3, "id": 403004},
                            "awayTeam": {"teamId": 851173, "seed": 2, "id": 403003},
                            "games": [
                                {
                                    "id": 4868943,
                                    "number": 1,
                                    "to": 28,
                                    "cap": 0,
                                    "home": 22,
                                    "away": 12,
                                    "isFinal": false,
                                    "_winner": null
                                }
                            ]
                        }
                    ]
                }
            ]
        },
        {
            "id": 261835,
            "name": "Pool Play",
            "bracketPlay": false,
            "poolPlay": true,
            "flights": [
                {
                    "id": 1,
                    "pools": [
                        {
                            "id": 326016,
                            "name": "1",
                            "teams": [
                                {"id": 100, "teamId": 851172, "seed": 1}
                            ],
                            "matches": [
                                {
                                    "id": 1217131,
                                    "number": 1,
                                    "court": 1,
                                    "startTime": "2026-01-09T09:00:00Z",
                                    "homeTeam": {"teamId": 851172, "seed": 1},
                                    "awayTeam": {"teamId": 851171, "seed": 3},
                                    "games": [
                                        {"to": 21, "cap": 23, "home": 1, "away": 0},
                                        {"to": 21, "cap": 23, "home": 0, "away": 0}
                                    ]
                                }
                            ]
                        }
                    ]
                }
            ]
        }
    ]
}
```

**Key structural differences:**

| | Bracket Days | Pool Days |
|-|-------------|-----------|
| Day flag | `"bracketPlay": true` | `"poolPlay": true` |
| Container path | `day.brackets[]` | `day.flights[].pools[]` |
| Format settings | `bracket.winnersMatchSettings.gameSettings[]` | Derived from each match's `games[]` array |
| Match number | `match.displayNumber` (bracket display #) | `match.number` (pool match #) |
| Team lookup | Via `division.teams[]` using `teamId` | Via `division.teams[]` using `teamId` |

### vMix Endpoint (Live Score Polling)

Returns match data formatted for vMix/OBS overlays. This is what the Swift app polls every 1 second for live score updates.

```
GET https://api.volleyballlife.com/api/v1.0/matches/{matchId}/vmix?bracket=true|false
```

**Auth required** (Bearer token + cookies).

The `bracket` parameter is **critical** — it determines which match ID namespace is queried:

| Parameter | ID Namespace | When to use |
|-----------|-------------|-------------|
| `bracket=true` | Bracket match IDs | Matches from `day.brackets[].matches[]` |
| `bracket=false` | Pool/DB match IDs | Matches from `day.flights[].pools[].matches[]` |

> **Warning:** The same numeric match ID can refer to completely different matches depending on this parameter. Bracket match 325751 and pool match 325751 are **different matches**.

**Response (array of 2 team objects):**
```json
[
    {
        "teamName": "Nathan Hicks / Reid Malone",
        "division": "Mens Unrated",
        "isMatch": false,
        "game1": 22,
        "game2": 0,
        "game3": 0,
        "logo": "",
        "players": [
            {"firstname": "Nathan", "lastname": "Hicks", "jersey": ""},
            {"firstname": "Reid", "lastname": "Malone", "jersey": ""}
        ]
    },
    {
        "teamName": "Marvin Pacheco / Derek Toliver",
        "division": "Mens Unrated",
        "isMatch": false,
        "game1": 12,
        "game2": 0,
        "game3": 0,
        "logo": "",
        "players": [
            {"firstname": "Marvin", "lastname": "Pacheco", "jersey": ""},
            {"firstname": "Derek", "lastname": "Toliver", "jersey": ""}
        ]
    }
]
```

The URL is constructed at scan time and stored in `VBLMatch.api_url`:
```python
# Bracket match:
f"https://api.volleyballlife.com/api/v1.0/matches/{match_id}/vmix?bracket=true"

# Pool match:
f"https://api.volleyballlife.com/api/v1.0/matches/{match_id}/vmix?bracket=false"
```

### Match Format Settings

Format settings are extracted differently for bracket vs pool matches:

**Bracket matches** — from `bracket.winnersMatchSettings.gameSettings[]`:
```python
winner_settings = bracket.get('winnersMatchSettings', {})
game_settings = winner_settings.get('gameSettings', [])
sets_to_win = (len(game_settings) + 1) // 2   # e.g., 3 settings → 2 sets to win
points_per_set = game_settings[0].get('to', 21)
point_cap = game_settings[0].get('cap') or None  # 0 is treated as None
```

**Pool matches** — from each match's own `games[]` array:
```python
games = match.get('games', [])
points_per_set = games[0].get('to', 21)
point_cap = games[0].get('cap') or None  # 0 is treated as None
```

**`cap` field semantics:**
- `0` or `null` = no cap (win by 2 with no limit)
- Any positive integer = hard cap (e.g., `cap=23` means the game ends at 23-22 regardless of the 2-point lead rule)
- Win condition: "first to `to`, win by 2, hard cap at `cap`"

### Match Settings Endpoint

```
GET  /matches/settings?matchId={matchId}&pool={true|false}
POST /matches/settings?matchId={matchId}&pool={true|false}
```

**Auth required** (returns 401 without auth).

---

## Scoring Lifecycle

```
┌─────────────────────────────────────────────────────────┐
│                    SCORING FLOW                         │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  1. GET /division/{id}/hydrate                          │
│     └─ Get match data (teams, games, bracket/pool IDs)  │
│                                                         │
│  2. POST /matches/scoring/start                         │
│     └─ Send liveStartDto → receive scoring KEY (UUID)   │
│                                                         │
│  3. POST /matches/scoring/update?key={KEY}    ◄─ LOOP   │
│     └─ Send {gameId, home, away} for each point         │
│                                                         │
│  4. POST /matches?ttids=false&key={KEY}       (optional)│
│     └─ Save full match state (game finals, new sets)    │
│                                                         │
│  5. POST /matches/scoring/end                           │
│     └─ Close the scoring session                        │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

---

## Scoring Endpoints

### 1. Start Scoring Session

Creates a live scoring session and returns a scoring key.

```
POST /matches/scoring/start
```

**Request Body:**
```json
{
    "name": "Nathan Hicks",
    "role": "ref",
    "key": null,
    "match": {
        "id": 325751,
        "poolId": null,
        "bracketId": 56262,
        "number": 126,
        "court": "1",
        "homeTeam": 403004,
        "homeTeamIds": null,
        "awayTeam": 403003,
        "awayTeamIds": null,
        "refTeam": null,
        "manualRefId": null,
        "startTime": "2026-01-09T09:30:00.000Z",
        "isMatch": false,
        "games": [
            {
                "id": 4868943,
                "number": 1,
                "to": 28,
                "cap": 0,
                "home": null,
                "away": null,
                "isFinal": false,
                "_winner": null
            }
        ],
        "settings": null
    }
}
```

**Field Reference:**

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Scorer's display name |
| `role` | string | `"ref"` or `"spec"` (referee or spectator) |
| `key` | string/null | `null` for new sessions; reuse existing key to resume |
| `match` | object | The `liveStartDto` — see [Data Models](#livestartdto) |

**Response (200):**
```json
{
    "id": 325751,
    "key": "7d158dba-ddfa-4cf5-ba04-fffc5eb4bd60",
    "match": {
        "id": 325751,
        "bracketId": 56262,
        "isWinners": true,
        "round": 0,
        "number": 126,
        "displayNumber": 2,
        "startTime": "2026-01-09T09:30:00.000Z",
        "court": "1",
        "isMatch": false,
        "isBye": false,
        "forfeit": false,
        "games": [
            {
                "away": 12,
                "cap": 0,
                "home": 22,
                "id": 4868943,
                "isFinal": false,
                "number": 1,
                "to": 28,
                "_winner": null,
                "dtModified": "1772340151462"
            }
        ],
        "homeTeam": {
            "id": 403004,
            "bracketId": 56262,
            "teamId": 851171,
            "seed": 3,
            "finish": 2,
            "adminRep": null,
            "fromPoolId": 0
        },
        "awayTeam": {
            "id": 403003,
            "bracketId": 56262,
            "teamId": 851173,
            "seed": 2,
            "finish": 3,
            "adminRep": null,
            "fromPoolId": 0
        },
        "refTeamId": 851172,
        "lineups": [],
        "dtModified": "1772340151462"
    }
}
```

> **Key Insight:** The `key` field in the response is a UUID that must be used for all subsequent scoring operations. Store it — it's your session token.

---

### 2. Update Score

Changes the score for a specific game. Call this for every point scored.

```
POST /matches/scoring/update?key=<scoring_key>
```

**Request Body:**
```json
{
    "id": 4868943,
    "home": 23,
    "away": 12
}
```

| Field | Type | Description |
|-------|------|-------------|
| `id` | int | The game ID (from the match's `games` array) |
| `home` | int | New home team score |
| `away` | int | New away team score |

**Response (200):**
```
true
```

Returns `true` on success, `false` if the key is invalid or expired.

> **Usage:** In the VBL frontend, this is called on every point change via a debounced watcher on `currentGame.home` and `currentGame.away`. You don't need to wait for the response before updating again.

---

### 3. Save Match Data

Persists the full match state including game completions, set transitions, and lineup changes. This is a general-purpose match save endpoint.

```
POST /matches?ttids=false&key=<scoring_key>
```

**Request Body:** Array of match DTOs (see [Full Match DTO](#full-match-dto)):
```json
[
    {
        "id": 325751,
        "poolId": null,
        "bracketId": 56262,
        "number": 126,
        "court": "1",
        "homeTeam": 403004,
        "awayTeam": 403003,
        "homeTeamIds": null,
        "awayTeamIds": null,
        "refTeam": null,
        "manualRefId": null,
        "startTime": "2026-01-09T09:30:00.000Z",
        "isMatch": true,
        "games": [
            {
                "id": 4868943,
                "number": 1,
                "to": 28,
                "cap": 0,
                "home": 21,
                "away": 18,
                "isFinal": true,
                "_winner": "home"
            },
            {
                "id": 0,
                "number": 2,
                "to": 28,
                "cap": 0,
                "home": 5,
                "away": 3,
                "isFinal": false,
                "_winner": null
            }
        ],
        "settings": null
    }
]
```

**Query Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `ttids` | bool | Whether to include tournament team IDs (`false` during scoring) |
| `key` | string | Scoring session key (optional — omit if not live scoring) |
| `applyTo` | string | Optional — apply changes to a specific scope |

**Response (200):** Empty or confirmation.

> **When to use:** The frontend calls `saveMatch` (this endpoint) when a game is completed (`isFinal: true`) and calls `saveScore` (the update endpoint) for individual point changes. Both are auto-saved via a debounced watcher, but `saveMatch` persists the complete match structure while `saveScore` only updates the current game's scores.

---

### 4. Check Key Validity

Verifies whether a scoring session key is still active.

```
POST /matches/scoring/keycheck?key=<scoring_key>&id=<match_id>
```

**No request body required.**

**Response (200):**
```
true
```

Returns `true` if the key is valid and the session is active, `false` otherwise.

> **Usage:** The VBL frontend checks the key when resuming a scoring session (e.g., after page reload). If the key is invalid, it clears the scoring state.

---

### 5. End Scoring Session

Closes the scoring session and releases the key.

```
POST /matches/scoring/end
```

**Request Body:** Match data or identifier (exact payload TBD — the `end` method signature matches `start`).

**Response (200):** Confirmation.

> **Note:** The exact payload for the end endpoint hasn't been fully traced through the frontend code. It likely accepts the match data or just the key.

---

## Data Models

### liveStartDto

The match start DTO sent in the `match` field of the start request. This is a computed property on the VBL `Match` model class.

```javascript
// From app.js (decompiled):
get liveStartDto() {
    return {
        id: this.id,                          // Match ID (bracket/pool match ID)
        poolId: this.poolId,                   // Pool ID (null for bracket matches)
        bracketId: this.bracketId,             // Bracket ID (null for pool matches)
        number: this.number,                   // Match number within bracket/pool
        court: this.court || null,             // Court name string
        homeTeam: this.homeTeam?.id ?? null,   // Home team ENTRY ID (not teamId!)
        homeTeamIds: this.homeTeamIds?.length ? this.homeTeamIds : null,
        awayTeam: this.awayTeam?.id ?? null,   // Away team ENTRY ID (not teamId!)
        awayTeamIds: this.awayTeamIds?.length ? this.awayTeamIds : null,
        refTeam: this.refTeam?.id ?? null,     // Ref team entry ID
        manualRefId: this.manualRefTeam?.id ?? null,
        startTime: this.startTime,             // ISO 8601 datetime
        isMatch: this.isMatch,                 // false = virtual, true = started
        games: this.games.map(g => g.dto),     // Array of Game DTOs
        settings: this.settings                // Match settings (usually null)
    }
}
```

> **Critical:** `homeTeam` and `awayTeam` are the bracket/pool team **entry** IDs (e.g., 403004), NOT the team IDs (e.g., 851171). The entry ID is the `id` field on the team object within the match, not the `teamId` field.

### Game DTO

The game DTO used inside the match's `games` array.

```javascript
// From app.js (decompiled):
get dto() {
    return {
        id: +this.id,         // Game ID (0 for new games)
        number: +this.number,  // Game/set number (1, 2, 3...)
        to: +this.to,         // Points to win (e.g., 21, 15, 28)
        cap: +this.cap,       // Point cap (0 = no cap)
        home: this.home ? +this.home : null,  // Home score (null = not started)
        away: this.away ? +this.away : null,  // Away score (null = not started)
        isFinal: this.isFinal,                // true = game is complete
        _winner: this._winner                  // "home", "away", or null
    }
}
```

**Winner determination logic (from JS):**
```javascript
get winner() {
    if (this._winner) return this._winner;       // Manual override
    if (this.isFinal && this.home > this.away) return "home";
    if (this.home >= this.to && this.away < this.home - 1) return "home";
    if (this.cap && this.home >= this.cap && this.away < this.home) return "home";
    // Mirror for away...
    return null;
}
```

### Full Match DTO

The complete match DTO used for `POST /matches` (save). This is larger than `liveStartDto` and includes filtered games.

```javascript
get dto() {
    return {
        id: this.id,
        poolId: this.poolId,
        bracketId: this.bracketId,
        number: this.number,
        court: this.court || null,
        homeTeam: this.homeTeam?.id ?? null,
        homeTeamIds: this.homeTeamIds?.length ? this.homeTeamIds : null,
        awayTeam: this.awayTeam?.id ?? null,
        awayTeamIds: this.awayTeamIds?.length ? this.awayTeamIds : null,
        refTeam: this.refTeam?.id > 0 ? this.refTeam.id : null,
        manualRefId: this.manualRefTeam?.id ?? null,
        startTime: this.startTime,
        isMatch: this.isMatch,
        games: this.games
            .filter(g => g.status || g.id)   // Only games that are active or have IDs
            .map(g => g.dto),
        settings: this.settings
    }
}
```

### Team Entry DTO

Teams in matches have two DTO formats depending on type:

**Pool Team:**
```json
{
    "id": 368706,
    "teamId": 258275,
    "poolId": 87867,
    "name": "Team Name",
    "seed": 3,
    "slot": 0,
    "finish": 1
}
```

**Bracket Team:**
```json
{
    "id": 403004,
    "teamId": 851171,
    "bracketId": 56262,
    "name": "Team Name",
    "seed": 3,
    "finish": 2
}
```

> The `id` is the team's **entry** ID within the bracket/pool (used in `liveStartDto.homeTeam`).
> The `teamId` is the actual team's global ID.

### VBLMatch (Scraper Output)

The Python scraper (`api_scraper.py`) extracts matches from the hydrate response and outputs `VBLMatch` objects with these fields:

```json
{
    "index": 0,
    "match_number": "2",
    "team1": "Nathan Hicks / Reid Malone",
    "team2": "Marvin Pacheco / Derek Toliver",
    "team1_seed": "3",
    "team2_seed": "2",
    "court": "1",
    "startTime": "9:30AM",
    "startDate": "Thu",
    "api_url": "https://api.volleyballlife.com/api/v1.0/matches/325751/vmix?bracket=true",
    "match_type": "Bracket Play",
    "type_detail": "Single Elim",
    "setsToWin": 1,
    "pointsPerSet": 28,
    "pointCap": null,
    "formatText": "1 set to 28",
    "team1_score": 0,
    "team2_score": 0
}
```

| Field | Type | Description |
|-------|------|-------------|
| `index` | int | 0-based position in results |
| `match_number` | str | `displayNumber` for bracket, `number` for pool matches |
| `team1` / `team2` | str | "First Last / First Last" |
| `team1_seed` / `team2_seed` | str | Seed number as string |
| `court` | str | Court name/number |
| `startTime` | str | Formatted time, e.g., "9:00AM" |
| `startDate` | str | Day of week, e.g., "Thu" |
| `api_url` | str | vMix URL with correct `bracket=true\|false` |
| `match_type` | str | "Bracket Play" or "Pool Play" |
| `type_detail` | str | "Single Elim", "Double Elim", "Pool 1", etc. |
| `setsToWin` | int | 1 for single-set, 2 for best-of-3, etc. |
| `pointsPerSet` | int | Points to win a set (21, 25, 28, etc.) |
| `pointCap` | int/null | Hard cap or null for win-by-2 |
| `formatText` | str | Human-readable, e.g., "1 set to 28" |
| `team1_score` / `team2_score` | int | Always 0 (live scores come from vMix polling) |

> These are the exact JSON keys the Swift `ScannerViewModel` and `AppViewModel` consume.

---

## SignalR Live Updates

VBL uses Azure SignalR Service for real-time push notifications. The SignalR hub is **not** used for scoring — scoring is done via REST API. The hub is used for general app-wide live updates.

### Connection Flow

1. Negotiate: `POST /live/negotiate?negotiateVersion=1` (auth required)
   - Returns `{url, accessToken}` for the Azure SignalR Service

2. Connect via WebSocket:
   ```
   wss://<hub_url>&access_token=<signalr_token>
   ```

3. Handshake: Send `{"protocol":"json","version":1}\x1e`

### Known Hub Methods (Server → Client)

| Method | Description |
|--------|-------------|
| `consoleLog` | Debug log messages |
| `StoreMutation` | Vuex store mutations (live data updates) |
| `StoreAction` | Vuex store action dispatches |
| `NoUser` | User session expired |

### Known Hub Methods (Client → Server)

| Method | Arguments | Description |
|--------|-----------|-------------|
| `AdClick` | `{id, page}` | Track ad clicks |
| `Lead` | event data | Lead tracking |
| `PlayerSearch` | search query | Player search |
| `FetchAds` | subdomain | Fetch ad content |
| `GetBid` | bid DTO | Get bid info |
| `CheckPass` | `{id, p}` | Check tournament pass |

> **Score updates propagate through `StoreMutation`**, not through dedicated scoring hub methods. When scores change via the REST API, the server pushes a `StoreMutation` to all connected clients watching that match.

---

## Important Concepts

### Virtual vs. Database Matches

From the VBL owner:
> "We don't actually create the match in the database until it is started. We only virtually create it. You can imagine how many dead matches we would have if we pre-created all of them."

- **Virtual matches** (`isMatch: false`): Exist only in the bracket structure returned by `/division/{id}/hydrate`. They have IDs, teams, and game templates, but no database record.
- **Database matches** (`isMatch: true`): Created by the Start API. Have a real database record and can be scored.
- **Match ID collision**: `GET /matches/325751` returns a pool match from the DB, not the bracket match 325751. Bracket match IDs are in a separate namespace.

### Scoring Key

The scoring key is a UUID generated by the server when you call `POST /matches/scoring/start`. It serves as:
- A session identifier for the scoring session
- An authorization token for score updates
- A mutex to prevent concurrent scoring of the same match

Keys can be checked with `keycheck` and reused to resume scoring after disconnection.

### ID Types

| ID Type | Example | Description |
|---------|---------|-------------|
| Match ID | 325751 | Bracket/pool match ID (can be virtual) |
| Game ID | 4868943 | Individual game/set ID |
| Team Entry ID | 403004 | Team's entry in a specific bracket/pool |
| Team ID | 851171 | Team's global ID |
| Bracket ID | 56262 | Bracket structure ID |
| Pool ID | 87867 | Pool structure ID |
| Day ID | 261836 | Tournament day ID |
| Division ID | 127872 | Division/event ID |

---

## Complete Working Example

```python
#!/usr/bin/env python3
"""
Complete example: Start a scoring session, update a score, and verify.
"""
import json
import ssl
import urllib.request

API = "https://volleyballlife-api-dot-net-8.azurewebsites.net"
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

HEADERS = {
    'Accept': 'application/json',
    'Content-Type': 'application/json',
    'User-Agent': 'Mozilla/5.0',
    'Referer': 'https://volleyballlife.com/',
    'Origin': 'https://volleyballlife.com',
}

# --- Step 1: Authenticate ---
login = {"username": "your@email.com", "password": "your_password"}
req = urllib.request.Request(
    f"{API}/account/login",
    data=json.dumps(login).encode(),
    headers=HEADERS, method='POST'
)
with urllib.request.urlopen(req, timeout=15, context=ctx) as resp:
    data = json.loads(resp.read().decode())
    token = data['access_token']
    cookies = [
        v.split(';')[0]
        for h, v in resp.headers.items()
        if h.lower() == 'set-cookie'
    ]

AUTH = {
    **HEADERS,
    'Authorization': f'Bearer {token}',
    'Cookie': '; '.join(cookies),
}

# --- Step 2: Get match data from hydrate ---
req = urllib.request.Request(f"{API}/division/127872/hydrate", headers=AUTH)
with urllib.request.urlopen(req, timeout=15, context=ctx) as resp:
    div = json.loads(resp.read().decode())

# Find the target match
match = None
for day in div['days']:
    for bracket in day['brackets']:
        for m in bracket['matches']:
            if m['id'] == 325751:
                match = m
                break

# --- Step 3: Start scoring session ---
start_payload = {
    "name": "Nathan Hicks",
    "role": "ref",
    "key": None,
    "match": {
        "id": match['id'],
        "poolId": None,
        "bracketId": match['bracketId'],
        "number": match['number'],
        "court": match.get('court'),
        "homeTeam": match['homeTeam']['id'],       # Entry ID, not teamId!
        "homeTeamIds": None,
        "awayTeam": match['awayTeam']['id'],       # Entry ID, not teamId!
        "awayTeamIds": None,
        "refTeam": None,
        "manualRefId": None,
        "startTime": match.get('startTime'),
        "isMatch": match.get('isMatch', False),
        "games": [
            {
                "id": g['id'],
                "number": g['number'],
                "to": g['to'],
                "cap": g['cap'],
                "home": None,
                "away": None,
                "isFinal": False,
                "_winner": None,
            }
            for g in match['games']
        ],
        "settings": None,
    },
}

req = urllib.request.Request(
    f"{API}/matches/scoring/start",
    data=json.dumps(start_payload).encode(),
    headers=AUTH, method='POST'
)
with urllib.request.urlopen(req, timeout=30, context=ctx) as resp:
    result = json.loads(resp.read().decode())
    scoring_key = result['key']
    print(f"Scoring key: {scoring_key}")

# --- Step 4: Update score (add a point to home) ---
game_id = match['games'][0]['id']
current_home = match['games'][0]['home'] or 0
current_away = match['games'][0]['away'] or 0

update_payload = {
    "id": game_id,
    "home": current_home + 1,
    "away": current_away,
}

req = urllib.request.Request(
    f"{API}/matches/scoring/update?key={scoring_key}",
    data=json.dumps(update_payload).encode(),
    headers=AUTH, method='POST'
)
with urllib.request.urlopen(req, timeout=15, context=ctx) as resp:
    success = resp.read().decode()
    print(f"Score updated: {success}")

# --- Step 5: Verify via vMix ---
req = urllib.request.Request(
    f"{API}/matches/{match['id']}/vmix?bracket=true",
    headers=AUTH
)
with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
    vmix = json.loads(resp.read().decode())
    for team in vmix:
        print(f"  {team['teamName']}: {team['game1']}")
```

---

## Endpoint Discovery Map

All known endpoints on the VBL API backend, discovered through systematic probing.

### Confirmed Endpoints (200/Working)

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/account/login` | No | Authenticate, get JWT |
| GET | `/division/{id}/hydrate` | No | Full division data |
| GET | `/matches/{id}/vmix?bracket=true\|false` | Yes | vMix overlay data |
| GET | `/matches/{id}` | Yes | DB match record (pool namespace) |
| POST | `/matches/scoring/start` | Yes | Start scoring session |
| POST | `/matches/scoring/update?key={k}` | Yes | Update game score |
| POST | `/matches/scoring/keycheck?key={k}&id={id}` | Yes | Check key validity |
| POST | `/matches/scoring/end` | Yes | End scoring session |
| POST | `/matches?ttids={bool}&key={k}` | Yes | Save match data (array) |
| DELETE | `/matches` | Yes | Delete matches |
| POST | `/live/negotiate?negotiateVersion=1` | Yes | SignalR negotiate |
| GET | `/event` | No | List events |
| POST | `/Day/{id}/brackets` | Yes | Save bracket data |
| GET | `/matches/settings?matchId={id}&pool={bool}` | Yes | Match settings |

### Controller Routes (Exist, Return 405 on Wrong Verb)

| Controller | Allowed Methods |
|-----------|----------------|
| `/matches` | DELETE, POST |
| `/Game` | (unknown) |
| `/Brackets` | (unknown) |
| `/Pool`, `/Pools` | (unknown) |
| `/Division` | (unknown) |
| `/Day` | (unknown) |
| `/Tournament` | (unknown) |

### Protected/Hidden

| Path | Status | Notes |
|------|--------|-------|
| `/swagger/v1/swagger.json` | 401 | Swagger docs exist but require elevated auth |
| `/swagger/index.html` | 401 | Swagger UI exists but protected |

### Other Discovered Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/Tournament/list` | Tournament list (has mapping error for byte→int) |
| POST | `/matches/settings` | Save match settings |
| POST | `/PointSystem` | Point system management |
| POST | `/PointSystem/Rerun/{id}` | Rerun point calculations |
| GET | `/LiveStream/player/{id}` | Livestream player data |
| POST | `/agreement` | Player agreements |

---

## Notes

- All timestamps use ISO 8601 format: `"2026-01-09T09:30:00.000Z"`
- The `dtModified` field is a Unix timestamp in milliseconds as a string: `"1772340151462"`
- Score values of `0` are stored as `null` in games that haven't started
- The `_winner` field uses an underscore prefix (unusual for JSON) because it maps to a C# backing field
- The `cap` field: `0` means no cap; any positive integer is the hard cap score
- Winner logic: Win by 2, OR reach cap. Example: `to=21, cap=23` means first to 21 wins by 2, hard cap at 23-22.
