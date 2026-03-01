#!/usr/bin/env python3
"""
API-based VBL Scraper - Direct HTTP calls, no browser needed.

Uses the public /division/{id}/hydrate endpoint to get all match data
in a single HTTP request (~1 second vs ~35 seconds with Playwright).

Falls back to the browser-based scraper if the API call fails.

Part of MultiCourtScore v2
"""

import json
import re
import ssl
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime
from typing import Dict, List, Optional, Tuple
from .core import ScanResult, VBLMatch, logger

API_BASE = "https://volleyballlife-api-dot-net-8.azurewebsites.net"
VMIX_BASE = "https://api.volleyballlife.com/api/v1.0/matches"


@dataclass
class URLParts:
    """Parsed VBL URL components."""
    tournament_id: Optional[int] = None
    division_id: Optional[int] = None
    day_id: Optional[int] = None        # also called "round" in URLs
    is_bracket: bool = False
    is_pool: bool = False
    pool_id: Optional[int] = None       # for direct pool URLs


def parse_vbl_url(url: str) -> Optional[URLParts]:
    """
    Parse a VBL URL to extract tournament, division, and day IDs.

    Supported URL patterns:
      /event/{tournId}/division/{divId}/round/{dayId}/brackets
      /event/{tournId}/division/{divId}/round/{dayId}/pools/{poolId}
      /event/{tournId}/division/{divId}/round/{dayId}/pools
    """
    parts = URLParts()

    # Extract tournament ID
    m = re.search(r'/event/(\d+)', url)
    if m:
        parts.tournament_id = int(m.group(1))

    # Extract division ID
    m = re.search(r'/division/(\d+)', url)
    if m:
        parts.division_id = int(m.group(1))

    # Extract day/round ID
    m = re.search(r'/round/(\d+)', url)
    if m:
        parts.day_id = int(m.group(1))

    # Determine type
    url_lower = url.lower()
    if 'bracket' in url_lower or 'playoff' in url_lower:
        parts.is_bracket = True
    elif 'pool' in url_lower:
        parts.is_pool = True
        # Check for specific pool ID
        m = re.search(r'/pools/(\d+)', url)
        if m:
            parts.pool_id = int(m.group(1))

    if not parts.division_id:
        return None

    return parts


def _make_ssl_context() -> ssl.SSLContext:
    """Create an SSL context that handles certificate issues."""
    # Try default context first (proper cert verification)
    ctx = ssl.create_default_context()
    try:
        req = urllib.request.Request(
            API_BASE + "/Theme?v=3",
            headers={'Accept': 'application/json', 'User-Agent': 'Mozilla/5.0'}
        )
        urllib.request.urlopen(req, timeout=3, context=ctx)
        return ctx
    except Exception:
        pass

    # Any failure — fall back to unverified context
    logger.info("[API] Using unverified SSL (cert chain unavailable)")
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _fetch_json(url: str, ssl_ctx: ssl.SSLContext) -> dict:
    """Fetch JSON from a URL."""
    req = urllib.request.Request(url, headers={
        'Accept': 'application/json',
        'Referer': 'https://volleyballlife.com/',
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
                      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    })
    with urllib.request.urlopen(req, timeout=15, context=ssl_ctx) as resp:
        return json.loads(resp.read().decode())


def _build_team_lookup(division_data: dict) -> Dict[int, dict]:
    """Build a teamId -> team info lookup from division data."""
    lookup = {}
    for team in division_data.get('teams', []):
        team_id = team.get('id')
        if team_id:
            lookup[team_id] = {
                'name': team.get('name', 'Unknown'),
                'seed': team.get('seed'),
                'players': [p.get('name', '') for p in team.get('players', [])],
            }
    return lookup


def _format_team_name(team_info: Optional[dict]) -> Optional[str]:
    """Format team name from lookup data (e.g., 'William Mota / Derek Strause' -> 'Mota / Strause')."""
    if not team_info:
        return None
    name = team_info.get('name', '')
    if not name:
        return None
    # The API already returns "FirstName LastName / FirstName LastName" format
    return name


def _format_time(iso_time: Optional[str]) -> Optional[str]:
    """Convert ISO timestamp to display time (e.g., '9:00AM')."""
    if not iso_time:
        return None
    try:
        dt = datetime.fromisoformat(iso_time.replace('Z', '+00:00'))
        hour = dt.hour
        minute = dt.minute
        ampm = 'AM' if hour < 12 else 'PM'
        if hour == 0:
            hour = 12
        elif hour > 12:
            hour -= 12
        if minute == 0:
            return f"{hour}:{minute:02d}{ampm}"
        return f"{hour}:{minute:02d}{ampm}"
    except (ValueError, AttributeError):
        return None


def _format_date(iso_time: Optional[str]) -> Optional[str]:
    """Convert ISO timestamp to display date (e.g., 'Thu')."""
    if not iso_time:
        return None
    try:
        dt = datetime.fromisoformat(iso_time.replace('Z', '+00:00'))
        return dt.strftime('%a')
    except (ValueError, AttributeError):
        return None


def _build_format_text(game_settings: List[dict], num_games: int) -> str:
    """Build human-readable format text from game settings."""
    if not game_settings:
        return ""

    parts = []
    for gs in game_settings:
        to = gs.get('to', 0)
        cap = gs.get('cap')
        if cap and cap > 0:
            parts.append(f"to {to} with a {cap} point cap")
        else:
            parts.append(f"to {to} with no cap")

    if num_games == 1:
        return f"1 set {parts[0]}" if parts else "1 set"

    if len(set(parts)) == 1:
        return f"Best of {num_games}, all sets {parts[0]}"

    return f"Best of {num_games}: " + ", ".join(
        f"set {i+1} {p}" for i, p in enumerate(parts)
    )


def _extract_bracket_matches(
    day: dict,
    team_lookup: Dict[int, dict],
) -> Tuple[List[VBLMatch], str, str]:
    """Extract matches from bracket data in a day."""
    matches = []
    match_type = "Bracket Play"
    type_detail = ""

    for bracket in day.get('brackets', []):
        bracket_name = bracket.get('name', 'Bracket')
        bracket_type = bracket.get('type', '')

        if 'single' in bracket_type.lower():
            type_detail = "Single Elim"
        elif 'double' in bracket_type.lower():
            type_detail = "Double Elim"
        else:
            type_detail = bracket_name

        # Get match format from bracket settings
        winner_settings = bracket.get('winnersMatchSettings', {})
        game_settings = winner_settings.get('gameSettings', [])
        sets_to_win = len(game_settings) if game_settings else 1
        # For single-set matches, setsToWin is 1
        # For best-of-3, it's 2 (need to win 2 of 3)
        if sets_to_win > 1:
            sets_to_win = (sets_to_win + 1) // 2  # e.g., 3 games -> 2 to win

        first_game = game_settings[0] if game_settings else {}
        points_per_set = first_game.get('to', 21)
        point_cap = first_game.get('cap')
        if point_cap == 0:
            point_cap = None

        format_text = _build_format_text(game_settings, len(game_settings))

        for idx, match in enumerate(bracket.get('matches', [])):
            match_id = match.get('id', 0)
            if match_id == 0 or match.get('isBye', False):
                continue

            home_team = match.get('homeTeam')
            away_team = match.get('awayTeam')

            home_team_id = home_team.get('teamId') if home_team else None
            away_team_id = away_team.get('teamId') if away_team else None

            home_info = team_lookup.get(home_team_id) if home_team_id else None
            away_info = team_lookup.get(away_team_id) if away_team_id else None

            # Handle TBD teams (e.g., "Match 2 Winner")
            team1_name = _format_team_name(home_info)
            team2_name = _format_team_name(away_info)
            if not team2_name and match.get('awayMap'):
                team2_name = str(match['awayMap'])

            team1_seed = str(home_team.get('seed', '')) if home_team and home_team.get('seed') else None
            team2_seed = str(away_team.get('seed', '')) if away_team and away_team.get('seed') else None

            display_number = match.get('displayNumber', match.get('number', idx + 1))

            vbl_match = VBLMatch(
                index=idx,
                match_number=str(display_number),
                team1=team1_name,
                team2=team2_name,
                team1_seed=team1_seed,
                team2_seed=team2_seed,
                court=str(match.get('court', '')) if match.get('court') else None,
                start_time=_format_time(match.get('startTime')),
                start_date=_format_date(match.get('startTime')),
                api_url=f"{VMIX_BASE}/{match_id}/vmix?bracket=true",
                match_type=match_type,
                type_detail=type_detail,
                sets_to_win=sets_to_win,
                points_per_set=points_per_set,
                point_cap=point_cap,
                format_text=format_text,
            )
            matches.append(vbl_match)

    return matches, match_type, type_detail


def _extract_pool_matches(
    day: dict,
    team_lookup: Dict[int, dict],
    pool_id_filter: Optional[int] = None,
) -> Tuple[List[VBLMatch], str, str]:
    """Extract matches from pool data in a day."""
    matches = []
    match_type = "Pool Play"
    type_detail = ""
    idx = 0

    for flight in day.get('flights', []):
        for pool in flight.get('pools', []):
            pid = pool.get('id', 0)
            pool_name = pool.get('name', '?')

            if pool_id_filter and pid != pool_id_filter:
                continue

            type_detail = f"Pool {pool_name}"

            # Build pool-specific team lookup (poolTeam -> teamId)
            pool_team_lookup = {}
            for pt in pool.get('teams', []):
                pt_id = pt.get('id')
                team_id = pt.get('teamId')
                if pt_id and team_id:
                    pool_team_lookup[pt_id] = team_id

            for match in pool.get('matches', []):
                match_id = match.get('id', 0)
                if match_id == 0:
                    continue

                home_team = match.get('homeTeam', {})
                away_team = match.get('awayTeam', {})

                # Pool matches reference pool team objects, not raw teamIds
                home_team_id = home_team.get('teamId') if isinstance(home_team, dict) else None
                away_team_id = away_team.get('teamId') if isinstance(away_team, dict) else None

                home_info = team_lookup.get(home_team_id) if home_team_id else None
                away_info = team_lookup.get(away_team_id) if away_team_id else None

                team1_name = _format_team_name(home_info)
                team2_name = _format_team_name(away_info)

                team1_seed = str(home_team.get('seed', '')) if isinstance(home_team, dict) and home_team.get('seed') else None
                team2_seed = str(away_team.get('seed', '')) if isinstance(away_team, dict) and away_team.get('seed') else None

                # Pool match format from games
                games = match.get('games', [])
                sets_to_win = len(games) if games else 1
                if sets_to_win > 1:
                    sets_to_win = (sets_to_win + 1) // 2

                first_game = games[0] if games else {}
                points_per_set = first_game.get('to', 21)
                point_cap = first_game.get('cap')
                if point_cap == 0:
                    point_cap = None

                format_text = _build_format_text(
                    [{'to': g.get('to', 21), 'cap': g.get('cap')} for g in games],
                    len(games)
                )

                match_number = match.get('number')
                court = match.get('court')

                vbl_match = VBLMatch(
                    index=idx,
                    match_number=str(match_number) if match_number else None,
                    team1=team1_name,
                    team2=team2_name,
                    team1_seed=team1_seed,
                    team2_seed=team2_seed,
                    court=str(court) if court else None,
                    start_time=_format_time(match.get('startTime')),
                    start_date=_format_date(match.get('startTime')),
                    api_url=f"{VMIX_BASE}/{match_id}/vmix?bracket=false",
                    match_type=match_type,
                    type_detail=type_detail,
                    sets_to_win=sets_to_win,
                    points_per_set=points_per_set,
                    point_cap=point_cap,
                    format_text=format_text,
                )
                matches.append(vbl_match)
                idx += 1

    return matches, match_type, type_detail


def scan_via_api(url: str) -> Optional[ScanResult]:
    """
    Scan a VBL URL using the public API (no browser needed).

    Returns a ScanResult on success, or None if the API approach fails
    (caller should fall back to browser-based scraping).
    """
    parts = parse_vbl_url(url)
    if not parts:
        logger.warning(f"[API] Could not parse URL: {url}")
        return None

    logger.info(f"[API] Attempting API scan: division={parts.division_id}, day={parts.day_id}")

    start_time = time.time()

    try:
        ssl_ctx = _make_ssl_context()

        # Single HTTP call to get all division data
        hydrate_url = f"{API_BASE}/division/{parts.division_id}/hydrate"
        logger.info(f"[API] Fetching {hydrate_url}")

        data = _fetch_json(hydrate_url, ssl_ctx)

        elapsed = time.time() - start_time
        logger.info(f"[API] Division data fetched in {elapsed:.2f}s")

        # Build team name lookup
        team_lookup = _build_team_lookup(data)
        logger.info(f"[API] Found {len(team_lookup)} teams")

        # Find the target day
        all_matches = []
        match_type = ""
        type_detail = ""

        for day in data.get('days', []):
            day_id = day.get('id')

            # Filter to specified day if provided
            if parts.day_id and day_id != parts.day_id:
                continue

            if parts.is_bracket or day.get('bracketPlay', False):
                bracket_matches, mt, td = _extract_bracket_matches(day, team_lookup)
                all_matches.extend(bracket_matches)
                if mt:
                    match_type = mt
                if td:
                    type_detail = td

            if parts.is_pool or day.get('poolPlay', False):
                pool_matches, mt, td = _extract_pool_matches(
                    day, team_lookup, parts.pool_id
                )
                all_matches.extend(pool_matches)
                if mt:
                    match_type = mt
                if td:
                    type_detail = td

        # Re-index matches
        for i, m in enumerate(all_matches):
            m.index = i

        elapsed = time.time() - start_time
        logger.info(f"[API] Extracted {len(all_matches)} matches in {elapsed:.2f}s total")

        if not all_matches:
            logger.warning("[API] No matches found via API, will try browser fallback")
            return None

        result = ScanResult(
            url=url,
            matches=all_matches,
            status="success",
            match_type=match_type,
            type_detail=type_detail,
        )

        return result

    except urllib.error.HTTPError as e:
        logger.warning(f"[API] HTTP {e.code} for division {parts.division_id}: {e.reason}")
        return None
    except urllib.error.URLError as e:
        logger.warning(f"[API] Network error: {e.reason}")
        return None
    except Exception as e:
        logger.warning(f"[API] Unexpected error: {e}")
        return None


# CLI interface for testing
if __name__ == "__main__":
    import sys

    if len(sys.argv) < 2:
        print("Usage: python -m vbl_scraper.api_scraper <url>")
        sys.exit(1)

    import logging
    logging.basicConfig(level=logging.INFO)

    url = sys.argv[1]
    result = scan_via_api(url)

    if result:
        print(json.dumps(result.to_dict(), indent=2))
    else:
        print("API scan failed, would fall back to browser scraper")
        sys.exit(1)
