#!/usr/bin/env python3
import json
import threading
import time
from dataclasses import dataclass
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from playwright.sync_api import sync_playwright


ROOT = Path(__file__).resolve().parents[1]
OVERLAY_HTML = ROOT / "MultiCourtScore" / "Resources" / "overlay.html"
OUTPUT_ROOT = ROOT / "output" / "playwright" / "overlay-visual"
HOST = "127.0.0.1"
PORT = 8765
POLL_SETTLE_MS = 1700
ANIMATION_FRAME_OFFSETS_MS = [0, 80, 160, 260, 420, 620, 900, 1300, 1900, 2500]
FAIL_CONSOLE_PATTERNS = [
    "Safety: forcing transitionInProgress=false",
    "Animation safety timer",
]


def base_score() -> dict[str, Any]:
    return {
        "team1": "Alpha Pair",
        "team2": "Bravo Pair",
        "score1": 0,
        "score2": 0,
        "set": 1,
        "status": "Pre-Match",
        "courtStatus": "waiting",
        "setsA": 0,
        "setsB": 0,
        "serve": "none",
        "setHistory": [],
        "seed1": "",
        "seed2": "",
        "setsToWin": 2,
        "pointsPerSet": 21,
        "pointCap": 21,
        "matchNumber": "1",
        "matchType": "Pool Play",
        "typeDetail": "",
        "nextMatch": "",
        "layout": "center",
        "showSocialBar": True,
        "holdDuration": 180000,
    }


def next_payload(a: str | None = None, b: str | None = None, label: str | None = None) -> dict[str, Any]:
    return {"a": a, "b": b, "label": label}


def merge(base: dict[str, Any], **updates: Any) -> dict[str, Any]:
    result = dict(base)
    result.update(updates)
    return result


class MutableOverlayState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.score = base_score()
        self.next_match = next_payload()

    def update(self, score: dict[str, Any] | None = None, next_match_data: dict[str, Any] | None = None) -> None:
        with self.lock:
            if score is not None:
                self.score = score
            if next_match_data is not None:
                self.next_match = next_match_data

    def snapshot(self) -> tuple[dict[str, Any], dict[str, Any]]:
        with self.lock:
            return dict(self.score), dict(self.next_match)


STATE = MutableOverlayState()


class OverlayHandler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args: Any) -> None:
        return

    def _json(self, payload: dict[str, Any]) -> None:
        data = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:  # noqa: N802
        if self.path in ("/", "/overlay.html"):
            body = OVERLAY_HTML.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/score.json":
            score, _ = STATE.snapshot()
            self._json(score)
            return

        if self.path == "/next.json":
            _, next_match_data = STATE.snapshot()
            self._json(next_match_data)
            return

        self.send_error(404)


@dataclass
class Scenario:
    name: str
    viewport: tuple[int, int]
    score: dict[str, Any]
    next_match: dict[str, Any]
    wait_ms: int = POLL_SETTLE_MS
    sequence: list[tuple[dict[str, Any], dict[str, Any], int]] | None = None
    expected_primary: tuple[str, str] | None = None


@dataclass
class AnimationCase:
    name: str
    viewport: tuple[int, int]
    initial_score: dict[str, Any]
    initial_next_match: dict[str, Any]
    transition_score: dict[str, Any]
    transition_next_match: dict[str, Any]
    initial_wait_ms: int = 1800
    frame_offsets_ms: list[int] | None = None
    pre_steps: list[tuple[dict[str, Any], dict[str, Any], int]] | None = None
    expected_initial_primary: tuple[str, str] | None = None
    expected_final_primary: tuple[str, str] | None = None
    focus_selector: str = "#overlay-wrapper"
    metric_selectors: list[str] | None = None


def build_scenarios() -> list[Scenario]:
    seed_center = base_score()
    seed_live = merge(
        seed_center,
        status="In Progress",
        courtStatus="live",
        score1=7,
        score2=6,
        serve="team1",
        setsA=1,
        setsB=1,
        set=3,
        setHistory=["21-18", "19-21"],
        nextMatch="Charlie Pair vs Delta Pair",
    )

    long_names = merge(
        seed_live,
        team1="Winner of Court Seven Semifinal / Alexandria Montgomery",
        team2="North Shore Elite / The Sandstorm Sisters",
        nextMatch="Winner of Match 42 vs Winner of Match 43",
    )

    shared_surnames = merge(
        seed_live,
        team1="Alexander Smith / Andrew Smith",
        team2="Avery Smith / Cameron Smith",
        nextMatch="Natalie Robertson / Nathaniel Robertson vs Megan Robertson / Mason Robertson",
        matchNumber="13",
    )

    extreme_full_names = merge(
        seed_live,
        team1="Maximilian Alexander Montgomery / Bartholomew Theodore Kensington",
        team2="Christopher Jonathan Worthington / Sebastian Elliot Hawthorne",
        nextMatch="Winner of Court Seven Semifinal vs Loser of Match 24",
        matchNumber="14",
    )

    return [
        Scenario(
            "center_01_first_load_pre_match",
            (1920, 1080),
            merge(seed_center, team1="Alice Smith / Beth Jones", team2="Cara Diaz / Dana Reed"),
            next_payload("Eva Long / Finn West", "Gina Shaw / Hale Young", "2"),
        ),
        Scenario(
            "center_02_intermission_queued_names",
            (1920, 1080),
            merge(seed_center, courtStatus="waiting", team1="Pool A #1", team2="Pool B #2", nextMatch=""),
            next_payload("Later Team A", "Later Team B", "3"),
        ),
        Scenario(
            "center_03_live_start_zero_zero",
            (1920, 1080),
            merge(seed_center, status="In Progress", courtStatus="live", serve="team2"),
            next_payload("Later Team A", "Later Team B", "3"),
        ),
        Scenario(
            "center_04_live_midset_next_match_bubble",
            (1920, 1080),
            seed_live,
            next_payload("Charlie Pair", "Delta Pair", "4"),
        ),
        Scenario(
            "center_05_rapid_score_update_left",
            (1920, 1080),
            merge(seed_live, score1=8, score2=6, serve="team1"),
            next_payload("Charlie Pair", "Delta Pair", "4"),
        ),
        Scenario(
            "center_06_rapid_score_update_right",
            (1920, 1080),
            merge(seed_live, score1=8, score2=8, serve="team2"),
            next_payload("Charlie Pair", "Delta Pair", "4"),
        ),
        Scenario(
            "center_07_deuce_extended_set",
            (1920, 1080),
            merge(seed_live, score1=23, score2=22, serve="team1", pointsPerSet=21, pointCap=25),
            next_payload("Charlie Pair", "Delta Pair", "4"),
        ),
        Scenario(
            "center_08_side_switch_normalized",
            (1920, 1080),
            merge(seed_live, team1="Bravo Pair", team2="Alpha Pair", score1=9, score2=10, serve="team2"),
            next_payload("Charlie Pair", "Delta Pair", "4"),
        ),
        Scenario(
            "center_09_postmatch_hold_with_next",
            (1920, 1080),
            merge(seed_live, status="Final", courtStatus="finished", score1=21, score2=18, setsA=2, setsB=1),
            next_payload("Echo Pair", "Foxtrot Pair", "5"),
            wait_ms=2300,
        ),
        Scenario(
            "center_10_intermission_after_final",
            (1920, 1080),
            merge(seed_center, team1="Echo Pair", team2="Foxtrot Pair", nextMatch="Golf Pair vs Hotel Pair"),
            next_payload("Golf Pair", "Hotel Pair", "6"),
        ),
        Scenario(
            "top_left_01_live_social_on",
            (1920, 1080),
            merge(seed_live, layout="top-left", team1="Alpha Pair", team2="Bravo Pair"),
            next_payload("Charlie Pair", "Delta Pair", "4"),
        ),
        Scenario(
            "top_left_02_live_social_off",
            (1920, 1080),
            merge(seed_live, layout="top-left", showSocialBar=False, score1=8, score2=7, serve="team2"),
            next_payload("Charlie Pair", "Delta Pair", "4"),
        ),
        Scenario(
            "top_left_03_postmatch_next_bubble",
            (1920, 1080),
            merge(seed_live, layout="top-left", status="Final", courtStatus="finished", score1=21, score2=17, setsA=2),
            next_payload("India Pair", "Juliet Pair", "7"),
            wait_ms=2300,
        ),
        Scenario(
            "top_left_04_long_names_stress",
            (1920, 1080),
            merge(long_names, layout="top-left"),
            next_payload("Winner of Match 42", "Winner of Match 43", "8"),
            expected_primary=("Winner of Ct Seven SF / A. Montgomery", "N. Elite / T. Sisters"),
        ),
        Scenario(
            "bottom_left_01_live_social_on",
            (1920, 1080),
            merge(seed_live, layout="bottom-left"),
            next_payload("Charlie Pair", "Delta Pair", "4"),
        ),
        Scenario(
            "bottom_left_02_next_bubble_social_off",
            (1920, 1080),
            merge(
                seed_live,
                layout="bottom-left",
                showSocialBar=False,
                score1=8,
                score2=7,
                serve="team1",
                nextMatch="India Pair vs Juliet Pair",
            ),
            next_payload("India Pair", "Juliet Pair", "7"),
        ),
        Scenario(
            "bottom_left_03_intermission_team_change",
            (1920, 1080),
            merge(seed_center, layout="bottom-left", team1="Kilo Pair", team2="Lima Pair"),
            next_payload("Mike Pair", "November Pair", "9"),
        ),
        Scenario(
            "bottom_left_04_long_names_stress",
            (1920, 1080),
            merge(long_names, layout="bottom-left", showSocialBar=False),
            next_payload("Winner of Match 42", "Winner of Match 43", "8"),
            expected_primary=("Winner of Ct Seven SF / A. Montgomery", "N. Elite / T. Sisters"),
        ),
        Scenario(
            "center_11_layout_cycle_return",
            (1920, 1080),
            merge(
                seed_live,
                layout="center",
                showSocialBar=True,
                team1="Winner of Match 24 / Alexandria Montgomery",
                team2="North Shore Elite / The Sandstorm Sisters",
                nextMatch="Winner of Match 42 vs Winner of Match 43",
            ),
            next_payload("Oscar Pair", "Papa Pair", "10"),
            sequence=[
                (merge(seed_live, layout="top-left", showSocialBar=True), next_payload("Oscar Pair", "Papa Pair", "10"), 1400),
                (merge(seed_live, layout="bottom-left", showSocialBar=False, nextMatch="India Pair vs Juliet Pair"), next_payload("India Pair", "Juliet Pair", "7"), 1400),
                (merge(seed_live, layout="center", showSocialBar=True, team1="Winner of Match 24 / Alexandria Montgomery", team2="North Shore Elite / The Sandstorm Sisters", nextMatch="Winner of Match 42 vs Winner of Match 43"), next_payload("Oscar Pair", "Papa Pair", "10"), 1500),
                (merge(seed_live, layout="top-left", showSocialBar=False), next_payload("Charlie Pair", "Delta Pair", "4"), 1200),
                (merge(seed_live, layout="center", showSocialBar=True, team1="Winner of Match 24 / Alexandria Montgomery", team2="North Shore Elite / The Sandstorm Sisters", nextMatch="Winner of Match 42 vs Winner of Match 43"), next_payload("Oscar Pair", "Papa Pair", "10"), 1700),
            ],
            expected_primary=("M24 Winner / A. Montgomery", "N. Elite / T. Sisters"),
        ),
        Scenario(
            "center_12_720p_regression_live",
            (1280, 720),
            merge(seed_live, layout="center"),
            next_payload("Oscar Pair", "Papa Pair", "10"),
        ),
        Scenario(
            "center_13_shared_surnames_stress",
            (1920, 1080),
            merge(shared_surnames, layout="center"),
            next_payload("Natalie Robertson / Nathaniel Robertson", "Megan Robertson / Mason Robertson", "11"),
            wait_ms=2600,
            expected_primary=("Alexander / Andrew Smith", "Avery / Cameron Smith"),
        ),
        Scenario(
            "center_14_transition_chain_stress",
            (1920, 1080),
            merge(extreme_full_names, layout="center", showSocialBar=False),
            next_payload("Winner of Match 24", "Loser of Match 24", "12"),
            wait_ms=2600,
            sequence=[
                (merge(seed_live, layout="center", status="Final", courtStatus="finished", score1=21, score2=18, setsA=2, setsB=1), next_payload("Winner of Match 24", "Loser of Match 24", "12"), 2300),
                (merge(seed_center, layout="center", team1="Winner of Match 24 / Alexandria Montgomery", team2="North Shore Elite / The Sandstorm Sisters"), next_payload("Winner of Match 42", "Winner of Match 43", "13"), 1800),
                (merge(extreme_full_names, layout="top-left", showSocialBar=True), next_payload("Winner of Match 24", "Loser of Match 24", "12"), 1400),
                (merge(extreme_full_names, layout="bottom-left", showSocialBar=False), next_payload("Winner of Match 24", "Loser of Match 24", "12"), 1400),
            ],
            expected_primary=("M. Montgomery / B. Kensington", "C. Worthington / S. Hawthorne"),
        ),
        Scenario(
            "top_left_05_720p_regression",
            (1280, 720),
            merge(seed_live, layout="top-left"),
            next_payload("Oscar Pair", "Papa Pair", "10"),
        ),
        Scenario(
            "top_left_06_shared_surnames_stress",
            (1920, 1080),
            merge(shared_surnames, layout="top-left", showSocialBar=False),
            next_payload("Natalie Robertson / Nathaniel Robertson", "Megan Robertson / Mason Robertson", "11"),
            wait_ms=2600,
            expected_primary=("Alexander / Andrew Smith", "Avery / Cameron Smith"),
        ),
        Scenario(
            "bottom_left_05_720p_regression",
            (1280, 720),
            merge(seed_live, layout="bottom-left"),
            next_payload("Oscar Pair", "Papa Pair", "10"),
        ),
        Scenario(
            "bottom_left_06_extreme_full_names",
            (1920, 1080),
            merge(extreme_full_names, layout="bottom-left", showSocialBar=False),
            next_payload("Winner of Match 24", "Loser of Match 24", "12"),
            wait_ms=2600,
            expected_primary=("M. Montgomery / B. Kensington", "C. Worthington / S. Hawthorne"),
        ),
    ]


def build_animation_cases() -> list[AnimationCase]:
    seed_center = base_score()
    seed_live = merge(
        seed_center,
        status="In Progress",
        courtStatus="live",
        score1=7,
        score2=6,
        serve="team1",
        setsA=1,
        setsB=1,
        set=3,
        setHistory=["21-18", "19-21"],
        nextMatch="Charlie Pair vs Delta Pair",
    )

    long_names = merge(
        seed_live,
        team1="Winner of Match 24 / Alexandria Montgomery",
        team2="North Shore Elite / The Sandstorm Sisters",
        nextMatch="Winner of Match 42 vs Winner of Match 43",
        matchNumber="24",
    )

    return [
        AnimationCase(
            "top_left_next_bar_score_growth_09_to_10",
            (1920, 1080),
            merge(seed_live, layout="top-left", showSocialBar=False, score1=9, score2=5, nextMatch="India Pair vs Juliet Pair", matchNumber="21"),
            next_payload("India Pair", "Juliet Pair", "21"),
            merge(seed_live, layout="top-left", showSocialBar=False, score1=10, score2=5, nextMatch="India Pair vs Juliet Pair", matchNumber="21"),
            next_payload("India Pair", "Juliet Pair", "21"),
            initial_wait_ms=2400,
            frame_offsets_ms=ANIMATION_FRAME_OFFSETS_MS,
            expected_initial_primary=("Alpha Pair", "Bravo Pair"),
            expected_final_primary=("Alpha Pair", "Bravo Pair"),
            metric_selectors=["#trad-board", "#next-bar"],
        ),
        AnimationCase(
            "center_return_after_corner_cycle",
            (1920, 1080),
            merge(long_names, layout="bottom-left", showSocialBar=False),
            next_payload("Oscar Pair", "Papa Pair", "10"),
            merge(long_names, layout="center", showSocialBar=True),
            next_payload("Oscar Pair", "Papa Pair", "10"),
            initial_wait_ms=1700,
            pre_steps=[
                (merge(long_names, layout="top-left", showSocialBar=True), next_payload("Oscar Pair", "Papa Pair", "10"), 1600),
            ],
            frame_offsets_ms=ANIMATION_FRAME_OFFSETS_MS,
            expected_initial_primary=("M24 Winner / A. Montgomery", "N. Elite / T. Sisters"),
            expected_final_primary=("M24 Winner / A. Montgomery", "N. Elite / T. Sisters"),
            metric_selectors=["#scorebug", "#trad-board"],
        ),
        AnimationCase(
            "bottom_left_match_change_to_intermission",
            (1920, 1080),
            merge(seed_live, layout="bottom-left", status="Final", courtStatus="finished", score1=21, score2=18, setsA=2, setsB=1, nextMatch="Kilo Pair vs Lima Pair", matchNumber="31"),
            next_payload("Kilo Pair", "Lima Pair", "31"),
            merge(seed_center, layout="bottom-left", team1="Kilo Pair", team2="Lima Pair", nextMatch="", matchNumber="32"),
            next_payload("Mike Pair", "November Pair", "33"),
            initial_wait_ms=2400,
            frame_offsets_ms=ANIMATION_FRAME_OFFSETS_MS + [3200],
            expected_initial_primary=("Alpha Pair", "Bravo Pair"),
            expected_final_primary=("Kilo Pair", "Lima Pair"),
            metric_selectors=["#trad-board", "#int-status-bar"],
        ),
    ]


def run_server() -> ThreadingHTTPServer:
    server = ThreadingHTTPServer((HOST, PORT), OverlayHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def ensure_output_dir() -> Path:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = OUTPUT_ROOT / stamp
    out_dir.mkdir(parents=True, exist_ok=True)
    return out_dir


def normalize_rect(rect: dict[str, Any] | None) -> dict[str, float | bool] | None:
    if rect is None:
        return None
    return {
        "x": round(rect.get("x", 0), 2),
        "y": round(rect.get("y", 0), 2),
        "width": round(rect.get("width", 0), 2),
        "height": round(rect.get("height", 0), 2),
        "visible": bool(rect.get("visible", False)),
    }


def primary_selectors(layout: str) -> tuple[str, str]:
    if layout == "center":
        return "#t1", "#t2"
    return "#trad-t1", "#trad-t2"


def closeup_selector(layout: str) -> str:
    return "#scorebug" if layout == "center" else "#trad-board"


def current_primary_text(page: Any, layout: str) -> list[str]:
    selectors = primary_selectors(layout)
    return page.evaluate(
        """(selectors) => selectors.map((selector) => {
            const el = document.querySelector(selector);
            return el ? (el.textContent || '').trim() : '';
        })""",
        list(selectors),
    )


def wait_for_scenario_state(page: Any, scenario: Scenario) -> None:
    layout = scenario.score.get("layout", "center")
    timeout = max(5000, scenario.wait_ms + 2500)
    page.wait_for_function(
        "(layout) => document.body.classList.contains('layout-' + layout)",
        arg=layout,
        timeout=timeout,
    )
    if scenario.expected_primary:
        selectors = primary_selectors(layout)
        page.wait_for_function(
            """(payload) => payload.selectors.every((selector, index) => {
                const el = document.querySelector(selector);
                return el && (el.textContent || '').trim() === payload.expected[index];
            })""",
            arg={"selectors": list(selectors), "expected": list(scenario.expected_primary)},
            timeout=timeout,
        )


def wait_for_primary_text(page: Any, layout: str, expected_primary: tuple[str, str], timeout: int = 7000) -> None:
    selectors = primary_selectors(layout)
    page.wait_for_function(
        """(payload) => payload.selectors.every((selector, index) => {
            const el = document.querySelector(selector);
            return el && (el.textContent || '').trim() === payload.expected[index];
        })""",
        arg={"selectors": list(selectors), "expected": list(expected_primary)},
        timeout=timeout,
    )


def capture_animation_metrics(page: Any, selectors: list[str]) -> dict[str, Any]:
    metrics = page.evaluate(
        """(selectors) => {
            const readRect = (selector) => {
                const el = document.querySelector(selector);
                if (!el) return null;
                const style = window.getComputedStyle(el);
                const rect = el.getBoundingClientRect();
                return {
                    x: rect.x,
                    y: rect.y,
                    width: rect.width,
                    height: rect.height,
                    visible: style.display !== 'none' && style.visibility !== 'hidden' && parseFloat(style.opacity || '1') > 0.01 && rect.width > 0 && rect.height > 0
                };
            };
            const result = {};
            selectors.forEach((selector) => {
                result[selector] = readRect(selector);
            });
            return {
                overlayState: window.overlayState || null,
                layoutClasses: document.body.className,
                results: result
            };
        }""",
        selectors,
    )
    return {
        "overlayState": metrics["overlayState"],
        "layoutClasses": metrics["layoutClasses"],
        "results": {selector: normalize_rect(rect) for selector, rect in metrics["results"].items()},
    }


def run_animation_case(page: Any, out_dir: Path, case: AnimationCase) -> dict[str, Any]:
    page.set_viewport_size({"width": case.viewport[0], "height": case.viewport[1]})
    if case.pre_steps:
        for score_step, next_step, wait_ms in case.pre_steps:
            STATE.update(score=score_step, next_match_data=next_step)
            time.sleep(wait_ms / 1000)

    STATE.update(score=case.initial_score, next_match_data=case.initial_next_match)
    time.sleep(case.initial_wait_ms / 1000)
    initial_layout = case.initial_score.get("layout", "center")
    page.wait_for_function(
        "(layout) => document.body.classList.contains('layout-' + layout)",
        arg=initial_layout,
        timeout=max(7000, case.initial_wait_ms + 2500),
    )
    initial_expected_primary = case.expected_initial_primary or (
        str(case.initial_score.get("team1", "")).strip(),
        str(case.initial_score.get("team2", "")).strip(),
    )
    wait_for_primary_text(page, initial_layout, initial_expected_primary, timeout=max(7000, case.initial_wait_ms + 2500))

    anim_dir = out_dir / "animations" / case.name
    anim_dir.mkdir(parents=True, exist_ok=True)

    initial_path = anim_dir / "initial.png"
    page.screenshot(path=str(initial_path), full_page=True)
    initial_primary = current_primary_text(page, initial_layout)
    initial_metrics = capture_animation_metrics(page, case.metric_selectors or [case.focus_selector])

    STATE.update(score=case.transition_score, next_match_data=case.transition_next_match)
    frame_offsets = case.frame_offsets_ms or ANIMATION_FRAME_OFFSETS_MS
    started = time.perf_counter()
    frames: list[dict[str, Any]] = []
    for offset in frame_offsets:
        elapsed_ms = (time.perf_counter() - started) * 1000
        if offset > elapsed_ms:
            time.sleep((offset - elapsed_ms) / 1000)
        frame_path = anim_dir / f"{offset:04d}ms.png"
        page.screenshot(path=str(frame_path), full_page=True)
        frames.append(
            {
                "offsetMs": offset,
                "screenshot": str(frame_path),
                "primary": current_primary_text(page, case.transition_score.get("layout", "center")),
                "metrics": capture_animation_metrics(page, case.metric_selectors or [case.focus_selector]),
            }
        )

    settled_failure = None
    if case.expected_final_primary:
        try:
            wait_for_primary_text(page, case.transition_score.get("layout", "center"), case.expected_final_primary, timeout=9000)
        except Exception as exc:  # noqa: BLE001
            settled_failure = str(exc)

    settled_path = anim_dir / "settled.png"
    page.screenshot(path=str(settled_path), full_page=True)
    return {
        "name": case.name,
        "viewport": list(case.viewport),
        "focusSelector": case.focus_selector,
        "initialScreenshot": str(initial_path),
        "initialPrimary": initial_primary,
        "initialExpectedPrimary": list(initial_expected_primary),
        "initialMetrics": initial_metrics,
        "expectedFinalPrimary": list(case.expected_final_primary) if case.expected_final_primary else None,
        "settledScreenshot": str(settled_path),
        "settledPrimary": current_primary_text(page, case.transition_score.get("layout", "center")),
        "settledFailure": settled_failure,
        "frames": frames,
    }


def main() -> int:
    out_dir = ensure_output_dir()
    scenarios = build_scenarios()
    animation_cases = build_animation_cases()
    server = run_server()
    console_messages: list[str] = []
    failures: list[str] = []
    report_path = out_dir / "report.json"
    trace_path = out_dir / "trace.zip"
    video_dir = out_dir / "videos"
    video_dir.mkdir(parents=True, exist_ok=True)

    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=False)
            context = browser.new_context(
                viewport={"width": 1920, "height": 1080},
                record_video_dir=str(video_dir),
                record_video_size={"width": 1280, "height": 720},
            )
            context.tracing.start(screenshots=True, snapshots=True, sources=True)
            page = context.new_page()

            def on_console(msg: Any) -> None:
                text = msg.text
                console_messages.append(text)
                if any(pattern in text for pattern in FAIL_CONSOLE_PATTERNS):
                    failures.append(f"console:{text}")

            page.on("console", on_console)
            page.goto(f"http://{HOST}:{PORT}/overlay.html", wait_until="networkidle")
            time.sleep(POLL_SETTLE_MS / 1000)

            results: list[dict[str, Any]] = []
            animation_results: list[dict[str, Any]] = []
            for scenario in scenarios:
                page.set_viewport_size({"width": scenario.viewport[0], "height": scenario.viewport[1]})
                if scenario.sequence:
                    for score_step, next_step, wait_ms in scenario.sequence:
                        STATE.update(score=score_step, next_match_data=next_step)
                        time.sleep(wait_ms / 1000)
                STATE.update(score=scenario.score, next_match_data=scenario.next_match)
                time.sleep(scenario.wait_ms / 1000)

                scenario_failure: str | None = None
                try:
                    wait_for_scenario_state(page, scenario)
                except Exception as exc:  # noqa: BLE001
                    scenario_failure = str(exc)
                    failures.append(f"{scenario.name}:{scenario_failure}")

                shot_path = out_dir / f"{scenario.name}.png"
                closeup_path = out_dir / f"{scenario.name}__close.png"
                page.screenshot(path=str(shot_path), full_page=True)
                page.locator(closeup_selector(scenario.score.get("layout", "center"))).screenshot(path=str(closeup_path))
                primary_text = current_primary_text(page, scenario.score.get("layout", "center"))
                results.append(
                    {
                        "name": scenario.name,
                        "viewport": list(scenario.viewport),
                        "screenshot": str(shot_path),
                        "closeup": str(closeup_path),
                        "layout": scenario.score.get("layout"),
                        "status": scenario.score.get("status"),
                        "courtStatus": scenario.score.get("courtStatus"),
                        "expectedPrimary": list(scenario.expected_primary) if scenario.expected_primary else None,
                        "actualPrimary": primary_text,
                        "failure": scenario_failure,
                    }
                )

            for animation_case in animation_cases:
                animation_result = run_animation_case(page, out_dir, animation_case)
                if animation_result["settledFailure"]:
                    failures.append(f"{animation_case.name}:{animation_result['settledFailure']}")
                animation_results.append(animation_result)

            context.tracing.stop(path=str(trace_path))
            browser.close()

        report = {
            "url": f"http://{HOST}:{PORT}/overlay.html",
            "trace": str(trace_path),
            "videos": [str(path) for path in sorted(video_dir.glob("*.webm"))],
            "failures": failures,
            "consoleMessages": console_messages,
            "scenarios": results,
            "animationCases": animation_results,
        }
        report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(f"Wrote visual QA artifacts to {out_dir}")
        if failures:
            print("Console failures detected:")
            for failure in failures:
                print(f"  - {failure}")
            return 1
        return 0
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    raise SystemExit(main())
