#!/usr/bin/env python3
"""Tests for the API-based VBL scraper."""

import json
import pytest
from unittest.mock import patch, MagicMock

from vbl_scraper.api_scraper import (
    parse_vbl_url,
    _build_team_lookup,
    _format_time,
    _format_date,
    _build_format_text,
    _extract_bracket_matches,
    _extract_pool_matches,
    scan_via_api,
)


class TestParseVBLURL:
    def test_bracket_url(self):
        url = "https://volleyballlife.com/event/34785/division/127872/round/261836/brackets"
        parts = parse_vbl_url(url)
        assert parts is not None
        assert parts.tournament_id == 34785
        assert parts.division_id == 127872
        assert parts.day_id == 261836
        assert parts.is_bracket is True
        assert parts.is_pool is False

    def test_pool_url(self):
        url = "https://volleyballlife.com/event/34785/division/127872/round/260841/pools/326016"
        parts = parse_vbl_url(url)
        assert parts is not None
        assert parts.tournament_id == 34785
        assert parts.division_id == 127872
        assert parts.day_id == 260841
        assert parts.is_pool is True
        assert parts.pool_id == 326016

    def test_pool_url_without_pool_id(self):
        url = "https://volleyballlife.com/event/34785/division/127872/round/260841/pools"
        parts = parse_vbl_url(url)
        assert parts is not None
        assert parts.is_pool is True
        assert parts.pool_id is None

    def test_invalid_url(self):
        result = parse_vbl_url("https://example.com/nothing")
        assert result is None

    def test_url_with_subdomain(self):
        url = "https://norcalbeach.volleyballlife.com/event/34785/division/127872/round/261836/brackets"
        parts = parse_vbl_url(url)
        assert parts is not None
        assert parts.division_id == 127872
        assert parts.is_bracket is True


class TestBuildTeamLookup:
    def test_basic(self):
        data = {
            "teams": [
                {"id": 100, "name": "Team Alpha", "seed": 1, "players": [
                    {"name": "Alice"}, {"name": "Bob"}
                ]},
                {"id": 200, "name": "Team Beta", "seed": 2, "players": [
                    {"name": "Charlie"}, {"name": "Diana"}
                ]},
            ]
        }
        lookup = _build_team_lookup(data)
        assert len(lookup) == 2
        assert lookup[100]["name"] == "Team Alpha"
        assert lookup[200]["seed"] == 2
        assert lookup[100]["players"] == ["Alice", "Bob"]

    def test_empty_teams(self):
        lookup = _build_team_lookup({"teams": []})
        assert len(lookup) == 0

    def test_missing_teams_key(self):
        lookup = _build_team_lookup({})
        assert len(lookup) == 0


class TestFormatTime:
    def test_morning(self):
        assert _format_time("2026-01-09T09:00:00.000Z") == "9:00AM"

    def test_afternoon(self):
        assert _format_time("2026-01-09T14:30:00Z") == "2:30PM"

    def test_noon(self):
        assert _format_time("2026-01-09T12:00:00Z") == "12:00PM"

    def test_midnight(self):
        assert _format_time("2026-01-09T00:00:00Z") == "12:00AM"

    def test_none(self):
        assert _format_time(None) is None

    def test_invalid(self):
        assert _format_time("not-a-time") is None


class TestFormatDate:
    def test_basic(self):
        result = _format_date("2026-01-09T09:00:00Z")
        assert result in ("Thu", "Fri")  # depends on timezone

    def test_none(self):
        assert _format_date(None) is None


class TestBuildFormatText:
    def test_single_set_no_cap(self):
        result = _build_format_text([{"to": 28, "cap": None}], 1)
        assert "28" in result
        assert "no cap" in result

    def test_single_set_with_cap(self):
        result = _build_format_text([{"to": 21, "cap": 23}], 1)
        assert "21" in result
        assert "23" in result

    def test_best_of_3(self):
        gs = [{"to": 21, "cap": 23}, {"to": 21, "cap": 23}, {"to": 15, "cap": 17}]
        result = _build_format_text(gs, 3)
        assert "Best of 3" in result


class TestExtractBracketMatches:
    def setup_method(self):
        self.team_lookup = {
            851172: {"name": "William Mota / Derek Strause", "seed": 1, "players": []},
            851174: {"name": "George Black / Daniel Wenger", "seed": 4, "players": []},
            851171: {"name": "Nathan Hicks / Reid Malone", "seed": 3, "players": []},
            851173: {"name": "Marvin Pacheco / Derek Toliver", "seed": 2, "players": []},
        }
        self.day = {
            "id": 261836,
            "name": "Playoffs",
            "bracketPlay": True,
            "brackets": [{
                "id": 56262,
                "name": "Playoffs",
                "type": "SINGLE_ELIM",
                "winnersMatchSettings": {
                    "gameSettings": [{"to": 28, "cap": None, "number": 1}]
                },
                "matches": [
                    {
                        "id": 325750,
                        "displayNumber": 1,
                        "number": 125,
                        "homeTeam": {"teamId": 851172, "seed": 1},
                        "awayTeam": {"teamId": 851174, "seed": 4},
                        "court": 1,
                        "startTime": "2026-01-09T09:00:00.000Z",
                        "isBye": False,
                        "isWinners": True,
                        "round": 0,
                        "games": [{"to": 28, "cap": 0, "home": 28, "away": 5}],
                    },
                    {
                        "id": 325751,
                        "displayNumber": 2,
                        "number": 126,
                        "homeTeam": {"teamId": 851171, "seed": 3},
                        "awayTeam": {"teamId": 851173, "seed": 2},
                        "court": 1,
                        "startTime": "2026-01-09T09:30:00.000Z",
                        "isBye": False,
                        "isWinners": True,
                        "round": 0,
                        "games": [{"to": 28, "cap": 0, "home": 23, "away": 12}],
                    },
                    {
                        "id": 0,  # Unplayed bye
                        "displayNumber": 3,
                        "isBye": True,
                        "homeTeam": None,
                        "awayTeam": None,
                        "games": [],
                    },
                ],
            }],
        }

    def test_extracts_valid_matches(self):
        matches, mt, td = _extract_bracket_matches(self.day, self.team_lookup)
        assert len(matches) == 2
        assert mt == "Bracket Play"
        assert "Single Elim" in td

    def test_match_fields(self):
        matches, _, _ = _extract_bracket_matches(self.day, self.team_lookup)
        m = matches[0]
        assert m.team1 == "William Mota / Derek Strause"
        assert m.team2 == "George Black / Daniel Wenger"
        assert m.team1_seed == "1"
        assert m.team2_seed == "4"
        assert m.court == "1"
        assert "325750" in m.api_url
        assert "bracket=true" in m.api_url
        assert m.sets_to_win == 1
        assert m.points_per_set == 28
        assert m.point_cap is None

    def test_skips_byes_and_zero_ids(self):
        matches, _, _ = _extract_bracket_matches(self.day, self.team_lookup)
        ids = [m.api_url for m in matches]
        assert not any("matches/0/" in u for u in ids)

    def test_match_numbers(self):
        matches, _, _ = _extract_bracket_matches(self.day, self.team_lookup)
        assert matches[0].match_number == "1"
        assert matches[1].match_number == "2"


class TestExtractPoolMatches:
    def setup_method(self):
        self.team_lookup = {
            851172: {"name": "Team A", "seed": 1, "players": []},
            851171: {"name": "Team B", "seed": 3, "players": []},
        }
        self.day = {
            "id": 260841,
            "name": "Pools",
            "poolPlay": True,
            "flights": [{
                "id": 1,
                "pools": [{
                    "id": 326016,
                    "name": "1",
                    "teams": [
                        {"id": 100, "teamId": 851172, "seed": 1},
                        {"id": 101, "teamId": 851171, "seed": 3},
                    ],
                    "matches": [
                        {
                            "id": 1217131,
                            "number": 1,
                            "homeTeam": {"teamId": 851172, "seed": 1},
                            "awayTeam": {"teamId": 851171, "seed": 3},
                            "court": 1,
                            "startTime": "2026-01-09T09:00:00Z",
                            "games": [
                                {"to": 21, "cap": 23, "home": 1, "away": 0},
                                {"to": 21, "cap": 23, "home": 0, "away": 0},
                            ],
                        },
                        {
                            "id": 0,
                            "number": 2,
                            "homeTeam": {"teamId": 851172},
                            "awayTeam": {"teamId": 851171},
                            "games": [],
                        },
                    ],
                }],
            }],
        }

    def test_extracts_pool_matches(self):
        matches, mt, td = _extract_pool_matches(self.day, self.team_lookup)
        assert len(matches) == 1  # Only id=1217131, not id=0
        assert mt == "Pool Play"

    def test_pool_match_fields(self):
        matches, _, _ = _extract_pool_matches(self.day, self.team_lookup)
        m = matches[0]
        assert m.team1 == "Team A"
        assert m.team2 == "Team B"
        assert "1217131" in m.api_url
        assert "bracket=false" in m.api_url
        assert m.points_per_set == 21
        assert m.point_cap == 23

    def test_pool_id_filter(self):
        matches, _, _ = _extract_pool_matches(self.day, self.team_lookup, pool_id_filter=999)
        assert len(matches) == 0

    def test_pool_id_filter_match(self):
        matches, _, _ = _extract_pool_matches(self.day, self.team_lookup, pool_id_filter=326016)
        assert len(matches) == 1


class TestScanViaAPI:
    def test_invalid_url_returns_none(self):
        result = scan_via_api("https://example.com/nothing")
        assert result is None

    def test_scan_result_format(self):
        """Verify the scan result has the exact keys the Swift parser expects."""
        # Mock the HTTP call
        mock_data = {
            "teams": [
                {"id": 1, "name": "Alpha / Beta", "seed": 1, "players": []},
                {"id": 2, "name": "Gamma / Delta", "seed": 2, "players": []},
            ],
            "days": [{
                "id": 100,
                "name": "Playoffs",
                "bracketPlay": True,
                "poolPlay": False,
                "brackets": [{
                    "id": 50,
                    "name": "Main",
                    "type": "SINGLE_ELIM",
                    "winnersMatchSettings": {
                        "gameSettings": [{"to": 21, "cap": 23}]
                    },
                    "matches": [{
                        "id": 999,
                        "displayNumber": 1,
                        "number": 1,
                        "homeTeam": {"teamId": 1, "seed": 1},
                        "awayTeam": {"teamId": 2, "seed": 2},
                        "court": 1,
                        "startTime": "2026-01-09T09:00:00Z",
                        "isBye": False,
                        "games": [{"to": 21, "cap": 23}],
                    }],
                }],
                "flights": [],
            }],
        }

        with patch('vbl_scraper.api_scraper._make_ssl_context') as mock_ssl, \
             patch('vbl_scraper.api_scraper._fetch_json', return_value=mock_data):

            result = scan_via_api(
                "https://volleyballlife.com/event/1/division/1/round/100/brackets"
            )

        assert result is not None
        assert result.status == "success"
        assert result.total_matches == 1

        d = result.to_dict()
        assert "url" in d
        assert "matches" in d
        assert "status" in d

        match = d["matches"][0]
        # These are the exact keys Swift expects
        required_keys = [
            "index", "match_number", "team1", "team2",
            "team1_seed", "team2_seed", "court", "startTime",
            "api_url", "match_type", "type_detail",
            "setsToWin", "pointsPerSet", "pointCap", "formatText",
        ]
        for key in required_keys:
            assert key in match, f"Missing required key: {key}"

        assert match["api_url"] == "https://api.volleyballlife.com/api/v1.0/matches/999/vmix?bracket=true"
        assert match["team1"] == "Alpha / Beta"
        assert match["team2"] == "Gamma / Delta"
