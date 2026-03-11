# Overlay visual QA plan

Persistent-session overlay validation uses one browser tab for the full run. The page is not refreshed between scenarios.

Artifacts:
- `output/playwright/overlay-visual/<timestamp>/*.png`
- `output/playwright/overlay-visual/<timestamp>/trace.zip`
- `output/playwright/overlay-visual/<timestamp>/report.json`

Primary scenarios:
- first load with pre-match teams
- queued-name intermission without live scoring
- live start at `0-0`
- live mid-set with next-match bubble
- rapid left/right score changes
- deuce / extended set
- side-switch normalization
- postmatch hold with next-match bubble
- intermission after final without refresh

Layout coverage:
- `center`
- `top-left`
- `bottom-left`

Stress coverage:
- long team names
- social bar on/off
- next-match bubble in trad layouts
- 1920x1080 baseline
- 1280x720 regression

Acceptance focus:
- no clipping
- no off-screen overflow
- no overlap between board and bubble stack
- smooth layout transitions without stale hidden elements
- stable social/next bubble behavior in `top-left` and `bottom-left`
- no console safety warnings during motion/state transitions
