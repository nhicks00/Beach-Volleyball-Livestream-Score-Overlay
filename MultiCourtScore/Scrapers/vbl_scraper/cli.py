#!/usr/bin/env python3
"""
VBL Scraper CLI
Command-line interface for VolleyballLife scraping

Uses the direct API endpoint (no browser/Playwright needed).
~1 second per URL via GET /division/{id}/hydrate.

Part of MultiCourtScore v2 - API-only architecture
"""

import argparse
import json
import sys
from pathlib import Path
from typing import List, Optional

from vbl_scraper.core import ScanResult, logger
from vbl_scraper.api_scraper import scan_via_api


def scan_urls(
    urls: List[str],
    output_file: Optional[Path] = None,
) -> List[ScanResult]:
    """
    Scan multiple VBL URLs via the public API.

    Each URL is scanned via a single HTTP GET to /division/{id}/hydrate,
    returning all match data in ~1 second per URL. No browser needed.

    Args:
        urls: List of bracket/pool URLs to scan
        output_file: Optional file to write results

    Returns:
        List of ScanResult objects
    """
    results = []

    for i, url in enumerate(urls):
        logger.info(f"[{i+1}/{len(urls)}] Scanning: {url[:80]}...")
        result = scan_via_api(url)

        if result and result.total_matches > 0:
            logger.info(f"  Found {result.total_matches} matches")
            results.append(result)
        else:
            logger.error(f"  No matches found for {url[:80]}")
            results.append(ScanResult(
                url=url,
                matches=[],
                status="error",
                error="API returned no matches for this URL",
            ))

    # Write results to file
    if output_file:
        _write_results(results, urls, output_file)

    return results


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


def main():
    parser = argparse.ArgumentParser(
        description='VBL Scraper - Extract match data from VolleyballLife (API-only)',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
Examples:
  %(prog)s https://volleyballlife.com/event/12345/division/67890/round/11111/brackets
  %(prog)s url1 url2 url3 --output results.json
        '''
    )

    parser.add_argument(
        'urls',
        nargs='*',
        help='URLs to scan (bracket or pool pages)'
    )

    parser.add_argument(
        '-o', '--output',
        type=Path,
        default=Path('complete_workflow_results.json'),
        help='Output file for results (default: complete_workflow_results.json)'
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

    # Require URLs for scanning
    if not args.urls:
        parser.error("No URLs provided. Use --help for usage.")

    # Run scan (pure API, no browser)
    results = scan_urls(
        urls=args.urls,
        output_file=args.output,
    )

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
