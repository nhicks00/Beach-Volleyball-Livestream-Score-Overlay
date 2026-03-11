# Broadcast Soak Plan

This plan is for the live event shape that matters here:

- `8` active beach courts in rotation
- self-ref or informal ref workflow
- frequent missing live scoring on Volleyball Life
- operator goal: zero manual queue babysitting during stream

## Objective

Prove that the app stays broadcast-safe for a long session:

- correct teams remain on air even when live scoring never starts
- accidental later-match scoring does not pin the wrong queue item on air
- final-score hold logic advances at the right time
- SignalR, polling, and overlay recovery remain operator-visible and self-healing

## Soak Setup

- Populate `8` courts with realistic queues of `3-6` matches each
- Use a mix of:
  - normal live-scored matches
  - no-score-until-final matches
  - placeholder/TBD bracket matches
  - one or two courts with intentional API noise
- Keep dashboard and at least one browser-source overlay open the entire run
- Keep runtime log and health endpoint available during the run

## Phases

### Phase 1: Baseline Stability

Duration: `30 minutes`

- Start all polling with healthy overlay server
- Confirm no court gets stuck idle or error unexpectedly
- Confirm queued team names remain visible during `Pre-Match` / `0-0` periods

Pass criteria:

- no unexpected queue jumps
- no hidden overlay-server failures
- no stale polling courts without a visible warning

### Phase 2: No Live Scoring Tournament Reality

Duration: `45 minutes`

- Feed repeated `Pre-Match` / `0-0` snapshots for active queue heads
- Enter final scores only at match end
- Confirm the app holds finals for the configured window or until next match really starts

Pass criteria:

- current match names remain correct while no live scoring exists
- finals do not disappear immediately
- next match takes over automatically once it truly starts or hold expires

### Phase 3: Accidental Queue Jumps

Duration: `30 minutes`

- Start scoring on match `3` while match `1` is still the real on-court match
- Remove those accidental scores back to `0-0`
- Then start real scoring on match `1`
- Repeat with match `2`

Pass criteria:

- app can smart-switch forward when a later match is genuinely active
- app can revert back to the earlier canonical queue head when later scoring was accidental
- app can switch back to the earlier live match without manual intervention

### Phase 4: Overlapping / Contradictory Scoring

Duration: `30 minutes`

- Make match `1` live
- Start accidental scoring on match `2` or `3`
- Regress the accidental match to `0-0`
- Continue the original live match

Pass criteria:

- current real live match stays on air if it is already live
- later accidental activity does not steal focus from an already-live current match

### Phase 5: Resilience and Recovery

Duration: `30 minutes`

- force overlay restart while polling is active
- stop SignalR mutations long enough to trigger fallback polling
- simulate API timeout / 401 / 500 behavior on one or two courts

Pass criteria:

- watchdog recovers overlay service
- fallback polling becomes visible in health output
- single-court failures remain isolated and operator-visible

## Monitoring During Soak

- dashboard health banner
- settings health section
- runtime log
- diagnostics export
- `http://localhost:<port>/health`

## Exit Criteria

- `./run_tests.sh --all` remains green before and after the soak
- targeted chaos suite remains green: `scripts/run_broadcast_chaos_suite.sh`
- no scenario requires manual queue correction to recover normal behavior
