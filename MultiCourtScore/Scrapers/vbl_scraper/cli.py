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
from typing import List, Optional, Tuple

from vbl_scraper.core import ScraperConfig, ScanResult, logger
from vbl_scraper.bracket import BracketScraper
from vbl_scraper.pool import PoolScraper
from vbl_scraper.parallel import ParallelScraper, scan_parallel
from vbl_scraper.api_scraper import scan_via_api


def _try_api_scan(urls: List[str]) -> Tuple[List[ScanResult], List[str]]:
    """
    Try to scan URLs via the direct API (no browser needed).

    Returns:
        Tuple of (successful results, remaining URLs that need browser fallback)
    """
    results = []
    remaining = []

    for url in urls:
        result = scan_via_api(url)
        if result and result.total_matches > 0:
            logger.info(f"[API] {result.total_matches} matches from {url[:60]}...")
            results.append(result)
        else:
            logger.info(f"[API] No results, will use browser fallback for {url[:60]}...")
            remaining.append(url)

    return results, remaining


async def scan_urls(
    urls: List[str],
    username: Optional[str] = None,
    password: Optional[str] = None,
    headless: bool = True,
    output_file: Optional[Path] = None,
    parallel: bool = False,
    max_concurrent: int = 4
) -> List[ScanResult]:
    """
    Scan multiple URLs and return combined results.

    Uses the fast API scraper first (~1s per URL), falling back to
    browser-based Playwright scraping if the API approach fails.

    Args:
        urls: List of bracket/pool URLs to scan
        username: VBL login username
        password: VBL login password
        headless: Run browser in headless mode
        output_file: Optional file to write results
        parallel: Use parallel scanning (4x faster for multiple URLs)
        max_concurrent: Max concurrent browser instances

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

    # FAST PATH: Try API scraper first (no browser needed, ~1s per URL)
    logger.info(f"Attempting fast API scan for {len(urls)} URL(s)...")
    api_results, remaining_urls = _try_api_scan(urls)

    all_results = list(api_results)

    if not remaining_urls:
        # All URLs handled by API - no browser needed!
        logger.info(f"All {len(urls)} URL(s) scanned via API (no browser needed)")
        if output_file:
            _write_results(all_results, urls, output_file)
        return all_results

    logger.info(f"API handled {len(api_results)} URL(s), {len(remaining_urls)} need browser fallback")

    # BROWSER FALLBACK for remaining URLs

    # PARALLEL MODE: Use concurrent browser instances
    if parallel and len(remaining_urls) > 1:
        logger.info(f"Using PARALLEL browser mode for {len(remaining_urls)} remaining URL(s)")

        parallel_result = await scan_parallel(
            remaining_urls,
            username=username,
            password=password,
            max_concurrent=max_concurrent,
            headless=headless
        )

        all_results.extend(parallel_result.results)

        # Write combined results to file
        if output_file:
            _write_results(all_results, urls, output_file)

        return all_results

    # SEQUENTIAL MODE: Single browser, process one at a time

    # Use bracket scraper (which also handles login for pools)
    async with BracketScraper(config) as scraper:
        for i, url in enumerate(remaining_urls):
            logger.info(f"\n[{i+1}/{len(remaining_urls)}] Processing (browser): {url}")

            # Determine if pool or bracket
            if '/pools/' in url.lower():
                # Re-initialize pool scraper with existing session
                pool_scraper = PoolScraper(config)
                pool_scraper.playwright = scraper.playwright
                pool_scraper.browser = scraper.browser
                pool_scraper.context = scraper.context
                pool_scraper.page = await scraper.context.new_page()

                result = await pool_scraper.scan(url, username, password)
                await pool_scraper.page.close()
            else:
                result = await scraper.scan(url, username, password)

            all_results.append(result)

            # Log summary
            if result.status == "success":
                logger.info(f"  Found {result.total_matches} matches")
            else:
                logger.error(f"  Error: {result.error}")

    # Write results to file
    if output_file:
        _write_results(all_results, urls, output_file)

    return all_results


def _write_results(results: List[ScanResult], urls: List[str], output_file: Path):
    """Write scan results to the output file."""
    combined = {
        'urls_scanned': len(urls),
        'total_matches': sum(r.total_matches for r in results),
        'results': [r.to_dict() for r in results],
        'status': 'success' if all(r.status == 'success' for r in results) else 'partial'
    }

    with open(output_file, 'w') as f:
        json.dump(combined, f, indent=2)

    logger.info(f"\nResults written to: {output_file}")


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
    
    parser.add_argument(
        '--parallel',
        action='store_true',
        help='Use parallel scanning (4x faster for multiple URLs)'
    )
    
    parser.add_argument(
        '--max-concurrent',
        type=int,
        default=4,
        help='Max concurrent browsers in parallel mode (default: 4)'
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
        output_file=args.output,
        parallel=args.parallel,
        max_concurrent=args.max_concurrent
    ))
    
    # Print summary
    total_matches = sum(r.total_matches for r in results)
    successful = sum(1 for r in results if r.status == 'success')
    
    print(f"\n{'='*50}")
    print(f"Scan Complete: {successful}/{len(results)} URLs successful")
    print(f"Total Matches Found: {total_matches}")
    print(f"Results: {args.output}")
    print(f"{'='*50}")
    
    # Return appropriate exit code
    sys.exit(0 if successful == len(results) else 1)


if __name__ == '__main__':
    main()
