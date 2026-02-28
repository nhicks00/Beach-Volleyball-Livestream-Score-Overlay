"""
Integration tests for the VBL scraper against live URLs.
These tests require playwright to be installed and internet access.

Run with: pytest tests/test_integration.py -v --timeout=120
Mark: These tests hit live VBL servers and may take 30-60 seconds each.
"""
import sys
import os
import json
import asyncio
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

# Test URLs - known bracket and pool pages
BRACKET_URL = "https://volleyballlife.com/event/34785/division/127872/round/261836/brackets"
POOL_URL = "https://volleyballlife.com/event/34785/division/127872/round/260841/pools/326016"


def check_playwright():
    """Check if playwright is available."""
    try:
        import playwright
        return True
    except ImportError:
        return False


pytestmark = pytest.mark.skipif(
    not check_playwright(),
    reason="Playwright not installed - run: pip install playwright && python -m playwright install chromium"
)


@pytest.fixture(scope="module")
def event_loop():
    loop = asyncio.new_event_loop()
    yield loop
    loop.close()


@pytest.fixture(scope="module")
def credentials():
    """Load credentials from app support directory."""
    cred_path = os.path.expanduser(
        "~/Library/Application Support/MultiCourtScore/credentials.json"
    )
    if os.path.exists(cred_path):
        with open(cred_path) as f:
            creds = json.load(f)
        return creds.get('username'), creds.get('password')
    return None, None


class TestBracketScan:
    """Test scanning a known bracket URL."""

    @pytest.mark.asyncio
    async def test_bracket_scan_returns_matches(self, credentials):
        from vbl_scraper.bracket import BracketScraper
        from vbl_scraper.core import ScraperConfig

        config = ScraperConfig(headless=True)
        async with BracketScraper(config) as scraper:
            username, password = credentials
            if username and password:
                await scraper.login(username, password)

            result = await scraper.scan(BRACKET_URL)

        assert result.status == "success", f"Scan failed: {result.error}"
        assert result.total_matches >= 3, f"Expected at least 3 matches, got {result.total_matches}"

        # Verify match structure
        for match in result.matches:
            assert match.index >= 0
            # All matches in this bracket should have an API URL
            assert match.api_url is not None, f"Match {match.index} missing api_url"
            assert 'api.volleyballlife.com' in match.api_url

    @pytest.mark.asyncio
    async def test_bracket_match_has_team_names(self, credentials):
        from vbl_scraper.bracket import BracketScraper
        from vbl_scraper.core import ScraperConfig

        config = ScraperConfig(headless=True)
        async with BracketScraper(config) as scraper:
            username, password = credentials
            if username and password:
                await scraper.login(username, password)

            result = await scraper.scan(BRACKET_URL)

        assert result.status == "success"
        # At least some matches should have team names
        matches_with_teams = [m for m in result.matches if m.team1 and m.team2]
        assert len(matches_with_teams) > 0, "No matches found with team names"

    @pytest.mark.asyncio
    async def test_bracket_match_has_format(self, credentials):
        from vbl_scraper.bracket import BracketScraper
        from vbl_scraper.core import ScraperConfig

        config = ScraperConfig(headless=True)
        async with BracketScraper(config) as scraper:
            username, password = credentials
            if username and password:
                await scraper.login(username, password)

            result = await scraper.scan(BRACKET_URL)

        assert result.status == "success"
        # Check format was detected
        for match in result.matches:
            assert match.sets_to_win >= 1
            assert match.points_per_set > 0

    @pytest.mark.asyncio
    async def test_bracket_to_dict_is_valid_json(self, credentials):
        from vbl_scraper.bracket import BracketScraper
        from vbl_scraper.core import ScraperConfig

        config = ScraperConfig(headless=True)
        async with BracketScraper(config) as scraper:
            username, password = credentials
            if username and password:
                await scraper.login(username, password)

            result = await scraper.scan(BRACKET_URL)

        # Convert to dict and back to JSON to verify serialization
        d = result.to_dict()
        json_str = json.dumps(d)
        parsed = json.loads(json_str)

        assert parsed['total_matches'] == result.total_matches
        assert len(parsed['matches']) == len(result.matches)


class TestPoolScan:
    """Test scanning a known pool URL."""

    @pytest.mark.asyncio
    async def test_pool_scan_returns_matches(self, credentials):
        from vbl_scraper.pool import PoolScraper
        from vbl_scraper.core import ScraperConfig

        config = ScraperConfig(headless=True)
        async with PoolScraper(config) as scraper:
            username, password = credentials
            if username and password:
                await scraper.login(username, password)

            result = await scraper.scan(POOL_URL)

        assert result.status == "success", f"Pool scan failed: {result.error}"
        assert result.total_matches > 0, "No pool matches found"
        assert result.match_type == "Pool Play"


class TestCLIIntegration:
    """Test the CLI entry point end-to-end."""

    @pytest.mark.asyncio
    async def test_cli_single_bracket_url(self, tmp_path):
        from vbl_scraper.cli import scan_urls
        from vbl_scraper.core import ScraperConfig

        output_file = tmp_path / "test_output.json"
        config = ScraperConfig(headless=True)

        cred_path = os.path.expanduser(
            "~/Library/Application Support/MultiCourtScore/credentials.json"
        )
        username, password = None, None
        if os.path.exists(cred_path):
            with open(cred_path) as f:
                creds = json.load(f)
            username = creds.get('username')
            password = creds.get('password')

        await scan_urls(
            urls=[BRACKET_URL],
            output_file=str(output_file),
            username=username,
            password=password,
            headless=True,
            parallel=False,
        )

        assert output_file.exists(), "Output file not created"
        with open(output_file) as f:
            data = json.load(f)

        assert data['status'] == 'success'
        assert data['total_matches'] >= 3

    @pytest.mark.asyncio
    async def test_cli_parallel_both_urls(self, tmp_path):
        """Test scanning bracket + pool together in parallel mode."""
        from vbl_scraper.cli import scan_urls
        from vbl_scraper.core import ScraperConfig

        output_file = tmp_path / "test_parallel_output.json"

        cred_path = os.path.expanduser(
            "~/Library/Application Support/MultiCourtScore/credentials.json"
        )
        username, password = None, None
        if os.path.exists(cred_path):
            with open(cred_path) as f:
                creds = json.load(f)
            username = creds.get('username')
            password = creds.get('password')

        await scan_urls(
            urls=[BRACKET_URL, POOL_URL],
            output_file=str(output_file),
            username=username,
            password=password,
            headless=True,
            parallel=True,
        )

        assert output_file.exists(), "Parallel output file not created"
        with open(output_file) as f:
            data = json.load(f)

        # Parallel mode should have results from both URLs
        assert 'results' in data or 'total_matches' in data
