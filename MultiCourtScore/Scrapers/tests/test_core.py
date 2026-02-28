"""
Tests for VBL core data models (VBLMatch, ScanResult).
Run with: pytest tests/test_core.py -v

Note: Uses direct file import to avoid the playwright dependency in __init__.py.
Tests that need VBLScraperBase are skipped if playwright is not installed.
"""
import sys
import os
import json
import importlib.util

# Direct import of the dataclasses from core.py, bypassing __init__.py
# We temporarily mock out playwright, then restore to avoid polluting
# other tests (like integration tests) that need the real playwright.
import unittest.mock

_saved_pw = sys.modules.get('playwright')
_saved_pw_api = sys.modules.get('playwright.async_api')
_pw_was_present = 'playwright' in sys.modules
_pw_api_was_present = 'playwright.async_api' in sys.modules

_mock_playwright = unittest.mock.MagicMock()
sys.modules['playwright'] = _mock_playwright
sys.modules['playwright.async_api'] = _mock_playwright

_scraper_dir = os.path.join(os.path.dirname(__file__), '..', 'vbl_scraper')
_spec = importlib.util.spec_from_file_location('vbl_scraper_core', os.path.join(_scraper_dir, 'core.py'))
_core = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_core)

# Restore original modules so integration tests can use real playwright
if _pw_was_present:
    sys.modules['playwright'] = _saved_pw
else:
    del sys.modules['playwright']

if _pw_api_was_present:
    sys.modules['playwright.async_api'] = _saved_pw_api
else:
    del sys.modules['playwright.async_api']

VBLMatch = _core.VBLMatch
ScanResult = _core.ScanResult
VBLScraperBase = _core.VBLScraperBase


class TestVBLMatch:
    """Test VBLMatch dataclass."""

    def test_default_values(self):
        m = VBLMatch(index=0)
        assert m.index == 0
        assert m.team1 is None
        assert m.team2 is None
        assert m.sets_to_win == 2
        assert m.points_per_set == 21
        assert m.point_cap is None
        assert m.team1_score == 0
        assert m.team2_score == 0

    def test_to_dict_keys(self):
        m = VBLMatch(
            index=0,
            team1="Player A / Player B",
            team2="Player C / Player D",
            team1_seed="1",
            team2_seed="2",
            court="1",
            start_time="9:00AM",
            start_date="Sat",
            api_url="https://api.volleyballlife.com/api/v1.0/matches/12345/vmix",
            match_number="1",
            sets_to_win=1,
            points_per_set=28,
        )
        d = m.to_dict()
        assert d['startTime'] == '9:00AM'
        assert d['startDate'] == 'Sat'
        assert d['setsToWin'] == 1
        assert d['pointsPerSet'] == 28
        assert d['pointCap'] is None
        assert d['api_url'] == 'https://api.volleyballlife.com/api/v1.0/matches/12345/vmix'
        assert d['match_number'] == '1'
        assert d['team1'] == 'Player A / Player B'
        assert d['team2'] == 'Player C / Player D'

    def test_to_dict_all_fields_present(self):
        m = VBLMatch(index=5)
        d = m.to_dict()
        expected_keys = {
            'index', 'match_number', 'team1', 'team2', 'team1_seed', 'team2_seed',
            'court', 'startTime', 'startDate', 'api_url', 'match_type', 'type_detail',
            'setsToWin', 'pointsPerSet', 'pointCap', 'formatText',
            'team1_score', 'team2_score'
        }
        assert set(d.keys()) == expected_keys

    def test_to_dict_with_scores(self):
        m = VBLMatch(index=0, team1_score=21, team2_score=18)
        d = m.to_dict()
        assert d['team1_score'] == 21
        assert d['team2_score'] == 18

    def test_to_dict_json_serializable(self):
        """Verify the dict can be serialized to JSON without errors."""
        m = VBLMatch(
            index=0, team1="A / B", team2="C / D",
            api_url="https://example.com", match_number="1",
            sets_to_win=1, points_per_set=28
        )
        json_str = json.dumps(m.to_dict())
        parsed = json.loads(json_str)
        assert parsed['index'] == 0
        assert parsed['setsToWin'] == 1


class TestScanResult:
    """Test ScanResult dataclass."""

    def test_empty_result(self):
        r = ScanResult(url="https://example.com")
        assert r.total_matches == 0
        assert r.status == "pending"
        assert r.error is None

    def test_with_matches(self):
        matches = [VBLMatch(index=0), VBLMatch(index=1), VBLMatch(index=2)]
        r = ScanResult(
            url="https://volleyballlife.com/event/34785/division/127872/round/261836/brackets",
            matches=matches,
            status="success",
            match_type="Bracket Play",
            type_detail="Main Bracket"
        )
        assert r.total_matches == 3
        assert r.status == "success"

    def test_to_dict_structure(self):
        m = VBLMatch(index=0, team1="A", team2="B")
        r = ScanResult(
            url="https://example.com",
            matches=[m],
            status="success",
            match_type="Bracket Play",
            type_detail="Winners Bracket"
        )
        d = r.to_dict()
        assert d['url'] == "https://example.com"
        assert d['total_matches'] == 1
        assert d['status'] == "success"
        assert d['match_type'] == "Bracket Play"
        assert d['type_detail'] == "Winners Bracket"
        assert len(d['matches']) == 1

    def test_error_result(self):
        r = ScanResult(url="https://bad.com", status="error", error="Login failed")
        d = r.to_dict()
        assert d['status'] == "error"
        assert d['error'] == "Login failed"
        assert d['total_matches'] == 0

    def test_to_dict_json_serializable(self):
        m = VBLMatch(index=0, team1="A", team2="B")
        r = ScanResult(url="https://example.com", matches=[m], status="success")
        json_str = json.dumps(r.to_dict())
        parsed = json.loads(json_str)
        assert parsed['total_matches'] == 1


class TestDetermineURLType:
    """Test URL type detection."""

    def test_bracket_url(self):
        scraper = VBLScraperBase.__new__(VBLScraperBase)
        mt, td = scraper.determine_url_type(
            "https://volleyballlife.com/event/34785/division/127872/round/261836/brackets"
        )
        assert mt == "Bracket Play"

    def test_pool_url(self):
        scraper = VBLScraperBase.__new__(VBLScraperBase)
        mt, td = scraper.determine_url_type(
            "https://volleyballlife.com/event/34785/division/127872/round/260841/pools/326016"
        )
        assert mt == "Pool Play"


class TestScanResultJSON:
    """Test that scan results match the expected JSON format for Swift consumption."""

    def test_matches_swift_expected_format(self):
        """Verify output matches what ScannerViewModel.swift's VBLMatch CodingKeys expects."""
        m = VBLMatch(
            index=0,
            match_number="1",
            team1="William Mota / Derek Strause",
            team2="George Black / Daniel Wenger",
            team1_seed="1",
            team2_seed="4",
            court="1",
            start_time="9:00AM",
            api_url="https://api.volleyballlife.com/api/v1.0/matches/325750/vmix?bracket=true",
            sets_to_win=1,
            points_per_set=28,
            format_text="All Matches Are 1 set to 28 with no cap",
            team1_score=28,
            team2_score=0
        )

        d = m.to_dict()

        # Swift CodingKeys mapping:
        # "match_number" -> matchNumber
        # "api_url" -> apiURL
        # "match_type" -> matchType
        # "type_detail" -> typeDetail
        # "startTime" -> startTime (already camelCase in dict)
        # "startDate" -> startDate (already camelCase in dict)
        # "setsToWin" -> setsToWin (already camelCase in dict)
        # "pointsPerSet" -> pointsPerSet
        # "pointCap" -> pointCap
        # "formatText" -> formatText
        assert 'index' in d
        assert 'match_number' in d
        assert 'team1' in d
        assert 'team2' in d
        assert 'team1_seed' in d
        assert 'team2_seed' in d
        assert 'court' in d
        assert 'startTime' in d
        assert 'startDate' in d
        assert 'api_url' in d
        assert 'setsToWin' in d
        assert 'pointsPerSet' in d
        assert 'pointCap' in d
        assert 'formatText' in d
        assert 'team1_score' in d
        assert 'team2_score' in d

    def test_wrapper_format(self):
        """Verify ScanResult.to_dict() matches ScanResultWrapper structure."""
        matches = [VBLMatch(index=0, team1="A", team2="B")]
        r = ScanResult(
            url="https://volleyballlife.com/...",
            matches=matches,
            status="success",
            match_type="Bracket Play",
            type_detail="Main Bracket"
        )
        d = r.to_dict()
        assert 'url' in d
        assert 'total_matches' in d
        assert 'matches' in d
        assert 'status' in d
        assert 'match_type' in d
        assert 'type_detail' in d
        assert isinstance(d['matches'], list)


class TestExistingResults:
    """Validate against a known-good scan result file."""

    def test_parse_existing_scan_result(self):
        result_path = os.path.join(
            os.path.dirname(__file__), '..', 'scan_results_EF0DD006.json'
        )
        if not os.path.exists(result_path):
            return  # skip if file not present

        with open(result_path) as f:
            data = json.load(f)

        assert data['status'] == 'success'
        assert data['total_matches'] == 3

        results = data['results']
        assert len(results) == 1

        matches = results[0]['matches']
        assert len(matches) == 3

        # Verify first match structure
        m = matches[0]
        assert m['team1'] == "William Mota / Derek Strause"
        assert m['team2'] == "George Black / Daniel Wenger"
        assert m['team1_seed'] == "1"
        assert m['team2_seed'] == "4"
        assert 'api.volleyballlife.com' in m['api_url']
        assert m['setsToWin'] == 1
        assert m['pointsPerSet'] == 28
        assert m['pointCap'] is None
