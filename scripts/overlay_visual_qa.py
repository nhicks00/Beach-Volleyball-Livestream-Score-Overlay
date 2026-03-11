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
        ),
        Scenario(
            "center_11_layout_cycle_return",
            (1920, 1080),
            merge(seed_live, layout="center", showSocialBar=True),
            next_payload("Oscar Pair", "Papa Pair", "10"),
        ),
        Scenario(
            "center_12_720p_regression_live",
            (1280, 720),
            merge(seed_live, layout="center"),
            next_payload("Oscar Pair", "Papa Pair", "10"),
        ),
        Scenario(
            "top_left_05_720p_regression",
            (1280, 720),
            merge(seed_live, layout="top-left"),
            next_payload("Oscar Pair", "Papa Pair", "10"),
        ),
        Scenario(
            "bottom_left_05_720p_regression",
            (1280, 720),
            merge(seed_live, layout="bottom-left"),
            next_payload("Oscar Pair", "Papa Pair", "10"),
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


def main() -> int:
    out_dir = ensure_output_dir()
    scenarios = build_scenarios()
    server = run_server()
    console_messages: list[str] = []
    failures: list[str] = []
    report_path = out_dir / "report.json"
    trace_path = out_dir / "trace.zip"

    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=False)
            context = browser.new_context(viewport={"width": 1920, "height": 1080})
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
            for scenario in scenarios:
                page.set_viewport_size({"width": scenario.viewport[0], "height": scenario.viewport[1]})
                STATE.update(score=scenario.score, next_match_data=scenario.next_match)
                time.sleep(scenario.wait_ms / 1000)

                shot_path = out_dir / f"{scenario.name}.png"
                page.screenshot(path=str(shot_path), full_page=True)
                results.append(
                    {
                        "name": scenario.name,
                        "viewport": list(scenario.viewport),
                        "screenshot": str(shot_path),
                        "layout": scenario.score.get("layout"),
                        "status": scenario.score.get("status"),
                        "courtStatus": scenario.score.get("courtStatus"),
                    }
                )

            context.tracing.stop(path=str(trace_path))
            browser.close()

        report = {
            "url": f"http://{HOST}:{PORT}/overlay.html",
            "trace": str(trace_path),
            "failures": failures,
            "consoleMessages": console_messages,
            "scenarios": results,
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
