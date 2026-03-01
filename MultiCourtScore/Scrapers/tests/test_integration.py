"""
Integration tests for the VBL scraper against live URLs.
These tests require internet access to hit the VBL API.

Run with: pytest tests/test_integration.py -v -s
Mark: These tests hit live VBL servers.
"""
import sys
import os
import json
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

# Test URLs - known bracket and pool pages
BRACKET_URL = "https://volleyballlife.com/event/34785/division/127872/round/261836/brackets"
POOL_URL = "https://volleyballlife.com/event/34785/division/127872/round/260841/pools/326016"


# ============================================================
# API scraper integration tests (primary — no browser needed)
# ============================================================

class TestAPIScanIntegration:
    """Test API-based scanning against live VBL servers."""

    @pytest.mark.slow
    def test_api_bracket_scan(self):
        from vbl_scraper.api_scraper import scan_via_api

        result = scan_via_api(BRACKET_URL)
        assert result is not None, "API scan returned None for bracket URL"
        assert result.status == "success"
        assert result.total_matches >= 3, f"Expected >= 3 matches, got {result.total_matches}"

        # At least some matches should have team names
        matches_with_teams = [m for m in result.matches if m.team1 and m.team2]
        assert len(matches_with_teams) > 0, "No matches found with team names"

        # Check format was detected
        for match in result.matches:
            assert match.sets_to_win >= 1
            assert match.points_per_set > 0

        # Verify JSON serialization
        d = result.to_dict()
        json_str = json.dumps(d)
        parsed = json.loads(json_str)
        assert parsed['total_matches'] == result.total_matches

    @pytest.mark.slow
    def test_api_pool_scan(self):
        from vbl_scraper.api_scraper import scan_via_api

        result = scan_via_api(POOL_URL)
        assert result is not None, "API scan returned None for pool URL"
        assert result.status == "success"
        assert result.total_matches > 0, "No pool matches found"
        assert result.match_type == "Pool Play"

    @pytest.mark.slow
    def test_api_match_url_structure(self):
        from vbl_scraper.api_scraper import scan_via_api

        result = scan_via_api(BRACKET_URL)
        assert result is not None

        for match in result.matches:
            assert match.api_url is not None
            assert 'api.volleyballlife.com' in match.api_url
            assert '/vmix' in match.api_url


# ============================================================
# CLI integration tests
# ============================================================

class TestCLIIntegration:
    """Test the CLI entry point end-to-end."""

    @pytest.mark.slow
    def test_cli_single_bracket_url(self, tmp_path):
        from vbl_scraper.cli import scan_urls

        output_file = tmp_path / "test_output.json"

        scan_urls(
            urls=[BRACKET_URL],
            output_file=output_file,
        )

        assert output_file.exists(), "Output file not created"
        with open(output_file) as f:
            data = json.load(f)

        assert data['status'] in ('success', 'partial'), f"CLI scan failed: {data.get('status')}"
        assert data['total_matches'] >= 3

    @pytest.mark.slow
    def test_cli_multiple_urls(self, tmp_path):
        """Test scanning bracket + pool together."""
        from vbl_scraper.cli import scan_urls

        output_file = tmp_path / "test_multi_output.json"

        scan_urls(
            urls=[BRACKET_URL, POOL_URL],
            output_file=output_file,
        )

        assert output_file.exists(), "Output file not created"
        with open(output_file) as f:
            data = json.load(f)

        assert 'results' in data
        assert data['total_matches'] >= 4  # 3+ bracket + 1+ pool
