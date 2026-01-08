#!/usr/bin/env python3
"""
VBL Scraper CLI
Command-line interface for VolleyballLife scraping

Part of MultiCourtScore v2 - Consolidated scraper architecture
"""

import argparse
import asyncio
import json
import sys
from pathlib import Path
from typing import List, Optional

from vbl_scraper.core import ScraperConfig, ScanResult, logger
from vbl_scraper.bracket import BracketScraper
from vbl_scraper.pool import PoolScraper


async def scan_urls(
    urls: List[str],
    username: Optional[str] = None,
    password: Optional[str] = None,
    headless: bool = True,
    output_file: Optional[Path] = None
) -> List[ScanResult]:
    """
    Scan multiple URLs and return combined results.
    
    Args:
        urls: List of bracket/pool URLs to scan
        username: VBL login username
        password: VBL login password
        headless: Run browser in headless mode
        output_file: Optional file to write results
        
    Returns:
        List of ScanResult objects
    """
    config = ScraperConfig(
        headless=headless,
        session_file=Path.home() / '.multicourtscore' / 'session.json',
        results_file=output_file
    )
    
    # Ensure config directory exists
    config.session_file.parent.mkdir(parents=True, exist_ok=True)
    
    all_results = []
    seed_cache = {}  # Cache for Teams tab seeds by division
    
    # Use bracket scraper (which also handles login for pools)
    async with BracketScraper(config) as scraper:
        for i, url in enumerate(urls):
            logger.info(f"\n[{i+1}/{len(urls)}] Processing: {url}")
            
            # Determine if pool or bracket
            if '/pools/' in url.lower():
                # For pools, first try to get seeds from Teams tab
                from .teams import TeamsScraper, derive_teams_url
                
                teams_url = derive_teams_url(url)
                division_key = teams_url if teams_url else url
                
                if teams_url and division_key not in seed_cache:
                    logger.info(f"  Fetching seeds from Teams tab: {teams_url}")
                    teams_scraper = TeamsScraper(config)
                    teams_scraper.playwright = scraper.playwright
                    teams_scraper.browser = scraper.browser
                    teams_scraper.context = scraper.context
                    teams_scraper.page = await scraper.context.new_page()
                    
                    seeds = await teams_scraper.scan(teams_url, username, password)
                    seed_cache[division_key] = seeds
                    await teams_scraper.page.close()
                    logger.info(f"  Cached {len(seeds)} team seeds for division")
                elif teams_url and division_key in seed_cache:
                    logger.info(f"  Using cached seeds ({len(seed_cache[division_key])} teams) - skipping Teams tab fetch")
                
                # Now scan the pool
                pool_scraper = PoolScraper(config)
                pool_scraper.playwright = scraper.playwright
                pool_scraper.browser = scraper.browser
                pool_scraper.context = scraper.context
                pool_scraper.page = await scraper.context.new_page()
                
                result = await pool_scraper.scan(url, username, password)
                await pool_scraper.page.close()
                
                # Merge seeds into results
                cached_seeds = seed_cache.get(division_key, {})
                if cached_seeds and result.matches:
                    for match in result.matches:
                        if not match.team1_seed and match.team1:
                            match.team1_seed = _find_seed(match.team1, cached_seeds)
                        if not match.team2_seed and match.team2:
                            match.team2_seed = _find_seed(match.team2, cached_seeds)
            else:
                # For brackets, also try to use cached seeds
                from .teams import TeamsScraper, derive_teams_url
                
                teams_url = derive_teams_url(url)
                division_key = teams_url if teams_url else url
                
                # Check if we have cached seeds for this division
                if teams_url and division_key not in seed_cache:
                    logger.info(f"  Fetching seeds from Teams tab: {teams_url}")
                    teams_scraper = TeamsScraper(config)
                    teams_scraper.playwright = scraper.playwright
                    teams_scraper.browser = scraper.browser
                    teams_scraper.context = scraper.context
                    teams_scraper.page = await scraper.context.new_page()
                    
                    seeds = await teams_scraper.scan(teams_url, username, password)
                    seed_cache[division_key] = seeds
                    await teams_scraper.page.close()
                    logger.info(f"  Cached {len(seeds)} team seeds for division")
                elif teams_url and division_key in seed_cache:
                    logger.info(f"  Using cached seeds ({len(seed_cache[division_key])} teams) - skipping Teams tab fetch")
                
                result = await scraper.scan(url, username, password)
                
                # Merge seeds into bracket results too
                cached_seeds = seed_cache.get(division_key, {})
                if cached_seeds and result.matches:
                    for match in result.matches:
                        if not match.team1_seed and match.team1:
                            match.team1_seed = _find_seed(match.team1, cached_seeds)
                        if not match.team2_seed and match.team2:
                            match.team2_seed = _find_seed(match.team2, cached_seeds)
            
            all_results.append(result)
            
            # Log summary
            if result.status == "success":
                logger.info(f"  Found {result.total_matches} matches")
            else:
                logger.error(f"  Error: {result.error}")
    
    # Write results to file
    if output_file:
        combined = {
            'urls_scanned': len(urls),
            'total_matches': sum(r.total_matches for r in all_results),
            'results': [r.to_dict() for r in all_results],
            'status': 'success' if all(r.status == 'success' for r in all_results) else 'partial'
        }
        
        with open(output_file, 'w') as f:
            json.dump(combined, f, indent=2)
        
        logger.info(f"\nResults written to: {output_file}")
    
    return all_results


def _find_seed(team_name: str, seeds: dict) -> str | None:
    """
    Find seed for a team name, handling partial matches.
    Team names might be "FirstName LastName / FirstName LastName" format.
    """
    if not team_name or not seeds:
        return None
    
    # Exact match
    if team_name in seeds:
        return seeds[team_name]
    
    # Normalize and try again
    normalized = ' '.join(team_name.split()).strip()
    if normalized in seeds:
        return seeds[normalized]
    
    # Partial match - check if any seed key is contained in team name or vice versa
    team_lower = team_name.lower()
    for seed_team, seed_num in seeds.items():
        if seed_team.lower() in team_lower or team_lower in seed_team.lower():
            return seed_num
    
    return None


def load_credentials() -> tuple:
    """Load credentials from config file"""
    creds_file = Path.home() / 'Library' / 'Application Support' / 'MultiCourtScore' / 'credentials.json'
    
    if creds_file.exists():
        try:
            with open(creds_file) as f:
                data = json.load(f)
            return data.get('username', ''), data.get('password', '')
        except Exception:
            pass
    
    return None, None


def main():
    parser = argparse.ArgumentParser(
        description='VBL Scraper - Extract match data from VolleyballLife',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
Examples:
  %(prog)s https://voltournament.volleyballlife.com/event/12345/brackets/67890
  %(prog)s url1 url2 url3 --output results.json
  %(prog)s --login-check
  %(prog)s url --no-headless  # Show browser window
        '''
    )
    
    parser.add_argument(
        'urls',
        nargs='*',
        help='URLs to scan (bracket or pool pages)'
    )
    
    parser.add_argument(
        '-u', '--username',
        help='VBL username (or set VBL_USERNAME env var)'
    )
    
    parser.add_argument(
        '-p', '--password',
        help='VBL password (or set VBL_PASSWORD env var)'
    )
    
    parser.add_argument(
        '-o', '--output',
        type=Path,
        default=Path('complete_workflow_results.json'),
        help='Output file for results (default: complete_workflow_results.json)'
    )
    
    parser.add_argument(
        '--no-headless',
        action='store_true',
        help='Show browser window instead of running headless'
    )
    
    parser.add_argument(
        '--login-check',
        action='store_true',
        help='Just check login status and exit'
    )
    
    parser.add_argument(
        '-v', '--verbose',
        action='store_true',
        help='Enable verbose logging'
    )
    
    args = parser.parse_args()
    
    # Set log level
    if args.verbose:
        logger.setLevel('DEBUG')
    
    # Get credentials
    username = args.username
    password = args.password
    
    if not username or not password:
        stored_user, stored_pass = load_credentials()
        username = username or stored_user
        password = password or stored_pass
    
    # Login check mode
    if args.login_check:
        async def check_login():
            config = ScraperConfig(
                headless=not args.no_headless,
                session_file=Path.home() / '.multicourtscore' / 'session.json'
            )
            
            async with BracketScraper(config) as scraper:
                is_logged_in = await scraper.check_login_status()
                
                if is_logged_in:
                    print("✓ Currently logged in")
                    return 0
                else:
                    print("✗ Not logged in")
                    
                    if username and password:
                        print("Attempting login...")
                        if await scraper.login(username, password):
                            print("✓ Login successful")
                            return 0
                        else:
                            print("✗ Login failed")
                            return 1
                    else:
                        print("No credentials available")
                        return 1
        
        sys.exit(asyncio.run(check_login()))
    
    # Require URLs for scanning
    if not args.urls:
        parser.error("No URLs provided. Use --help for usage.")
    
    # Run scan
    results = asyncio.run(scan_urls(
        urls=args.urls,
        username=username,
        password=password,
        headless=not args.no_headless,
        output_file=args.output
    ))
    
    # Print summary
    total_matches = sum(r.total_matches for r in results)
    successful = sum(1 for r in results if r.status == 'success')
    
    print(f"\n{'='*50}")
    print(f"Scan Complete: {successful}/{len(results)} URLs successful")
    print(f"Total Matches Found: {total_matches}")
    print(f"Results: {args.output}")
    print(f"{'='*50}")
    
    # Return success (0) if we found any matches, otherwise 1
    # This prevents false "error" warnings when matches were found
    sys.exit(0 if total_matches > 0 else 1)


if __name__ == '__main__':
    main()
