# SignalR Integration — Handoff & Testing Guide

## Branch: `feature/signalr-integration`

## What This Is

Phase 1 of integrating VBL's Azure SignalR Service for instant score push updates. The app currently polls VBL vMix endpoints every ~1.5s per court. VBL's backend pushes score changes via SignalR `StoreMutation` messages. Connecting to SignalR would give us instant updates instead of polling lag.

**Phase 1 is listener-only:** connect to SignalR, log all mutations to the app's Logs panel for schema discovery. Polling continues unchanged as the primary data source. Phase 2 (future) will parse the discovered mutation payloads and wire them into the scoring pipeline.

## What Was Built

### New Files
- **`MultiCourtScore/Services/Networking/VBLSignalRClient.swift`** (~280 lines) — Actor implementing the full SignalR JSON protocol over WebSocket using `URLSessionWebSocketTask`. No third-party dependencies.
- **`MultiCourtScoreTests/VBLSignalRClientTests.swift`** — 35 unit tests for supporting types.

### Modified Files
- **`Constants.swift`** — Added `signalRPingInterval` (15s), `signalRMaxReconnectDelay` (60s), `signalRBaseReconnectDelay` (2s)
- **`ConfigStore.swift`** — Added `signalREnabled: Bool = false` to `AppSettings`
- **`AppViewModel.swift`** — Added `signalRStatus` published property, `signalRClient` service, `SignalRDelegate` conformance, lifecycle methods (`startSignalR`, `stopSignalR`, `setSignalREnabled`, `reconnectSignalRIfNeeded`)
- **`ScannerViewModel.swift`** — Added `addSignalRLog()` public method for piping SignalR messages to the log panel
- **`SettingsView.swift`** — Added "Live Push (SignalR)" section with toggle + status indicator; credential save triggers `reconnectSignalRIfNeeded()`
- **`DashboardView.swift`** — Added SignalR status pill in the footer status bar (only visible when enabled)

### Connection Flow (in `VBLSignalRClient`)
1. **Authenticate** — `POST /account/login` with username/password → JWT + cookies
2. **Negotiate** — `POST /live/negotiate?negotiateVersion=1` with JWT → Azure SignalR `{url, accessToken}`
3. **WebSocket** — Convert `https://` → `wss://` (Azure returns HTTPS URLs), connect with `access_token` as query param
4. **Handshake** — Send `{"protocol":"json","version":1}\x1E`, expect `{}\x1E` back
5. **Receive loop** — Process `\x1E`-delimited JSON frames, dispatch by `type` (1=invocation, 6=ping, 7=close)
6. **Ping loop** — Send `{"type":6}\x1E` every 15s
7. **Reconnect** — Exponential backoff 2s → 4s → 8s → ... → 60s cap
8. **Re-auth** — On `NoUser` invocation, clear JWT and reconnect (triggers fresh auth)

### SignalR Message Targets Handled
- `StoreMutation` — Logs mutation name + payload to the app's Logs panel via delegate
- `StoreAction` — Logged to console
- `NoUser` — Triggers re-authentication
- `consoleLog` — Logged to console

## What Was Tested

### Passing (confirmed working)
- All 35 new unit tests pass (status labels, colors, equatable, AnyCodable decoding, frame splitting, message type parsing, error descriptions)
- All existing 51 Swift tests still pass (1 pre-existing failure in `CourtTests/create_setsDefaults` — unrelated)
- Clean build with no new warnings
- **Auth** (`POST /account/login`) — returns 200, JWT token, 4 cookies
- **Negotiate** (`POST /live/negotiate`) — returns 200, Azure SignalR URL + access token, `availableTransports: []` (normal for Azure SignalR)
- **`https://` → `wss://` scheme conversion** — bug found and fixed during testing (Azure negotiate returns HTTPS URLs but `URLSessionWebSocketTask` requires WSS)

### NOT yet tested (why you're here)
- **WebSocket connection to Azure SignalR** — This is the critical piece. The WebSocket upgrade handshake returns HTTP 403, but it's being blocked by **McAfee Web Gateway** (a corporate/ISP web proxy) on the original dev network. The 403 response body is an HTML page from McAfee, not from Azure. The code itself is believed correct but needs testing on an unfiltered network.
- **SignalR handshake** — `{"protocol":"json","version":1}\x1E` → `{}\x1E`
- **Receiving actual `StoreMutation` messages** — Need a live VBL event to generate them
- **Reconnection behavior** — Kill network, wait for reconnect
- **UI integration** — Toggle in Settings, status pill in Dashboard, logs in Logs tab

## How to Test

### Prerequisites
- VBL credentials must be saved in the app (Settings > Credentials tab)
- A network that doesn't have a web proxy blocking WebSocket connections to `*.service.signalr.net`
- Ideally a live VBL event running (for `StoreMutation` messages), though connection/handshake can be tested without one

### Quick Smoke Test
1. Build and run the app (`Cmd+R` or `xcodebuild build -scheme MultiCourtScore`)
2. Open Settings > General tab
3. Scroll to "Live Push (SignalR)" section
4. Toggle ON "Enable SignalR push updates"
5. Watch the status indicator:
   - Should go from "Disabled" → "Connecting..." → "Connected" (green)
   - If it shows "No Credentials" → save credentials first in Credentials tab
   - If it shows "Failed: ..." → check console logs for details
6. Open Settings > Logs tab to see SignalR messages
7. If a live event is running, you should see `[SignalR] StoreMutation` entries appear

### Dashboard Status Bar
When SignalR is enabled, a status pill appears in the bottom status bar showing connection state with a colored dot (green=connected, amber=connecting/reconnecting, red=failed).

### Console Logging
The client prints detailed logs to stdout prefixed with `[SignalR]`:
- `[SignalR] Authenticated as <email>`
- `[SignalR] Negotiated, connecting to Azure SignalR`
- `[SignalR] Handshake complete`
- `[SignalR] StoreMutation: <mutationName>`
- `[SignalR] Reconnecting in Ns (attempt N) — <reason>`

### Standalone Connection Test (if needed)
You can write a quick Swift script to test the connection flow without the full app. The key endpoints:
- Auth: `POST https://volleyballlife-api-dot-net-8.azurewebsites.net/account/login`
- Negotiate: `POST https://volleyballlife-api-dot-net-8.azurewebsites.net/live/negotiate?negotiateVersion=1`
- WebSocket: Connect to the `url` from negotiate (convert `https://` → `wss://`), append `access_token=<token>` as query param

### What to Look For
1. **Connection succeeds** — Status shows "Connected" (green). This confirms the code works end-to-end.
2. **StoreMutation messages** — During a live event, the Logs tab should show mutation entries. We need to discover the payload schema for Phase 2.
3. **Reconnection** — If you disconnect WiFi and reconnect, the client should automatically reconnect with exponential backoff.
4. **Toggle behavior** — Enabling/disabling the toggle should cleanly start/stop the connection.
5. **Credential save** — Saving new credentials while SignalR is enabled should trigger a reconnect.

## Key Files for Reference
| File | Purpose |
|------|---------|
| `MultiCourtScore/Services/Networking/VBLSignalRClient.swift` | The SignalR client actor — all connection logic |
| `MultiCourtScore/ViewModels/AppViewModel.swift` | Integration point — search for `signalR` (lines ~18, ~25, ~70-76, ~1486-1540) |
| `MultiCourtScore/Views/Settings/SettingsView.swift` | UI toggle — search for `SignalR` (~line 297) |
| `MultiCourtScore/Views/Dashboard/DashboardView.swift` | Status pill — search for `signalR` (~line 511) |

## VBL API Context (from MEMORY.md)
- Backend: `https://volleyballlife-api-dot-net-8.azurewebsites.net`
- Auth returns `access_token` (JWT) and sets cookies
- The negotiate endpoint is at `/live/negotiate` — this is the ASP.NET Core SignalR negotiate for the `/live` hub
- Azure SignalR Service hostname: `vbl-signalr.service.signalr.net`
- The hub is named `signalrserverhub`

## Known Issues / Gotchas
- **McAfee Web Gateway** blocks WebSocket upgrades on some networks (returns HTML 403 page). The code is correct; it's a network-level block.
- **`availableTransports: []`** in negotiate response is normal for Azure SignalR Service (client connects directly to Azure, not app server).
- **No live event = no StoreMutation messages.** The connection will succeed and stay open, but you'll only see ping/pong traffic until someone is actively scoring on VBL.
