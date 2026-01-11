#!/usr/bin/env python3
"""
Parallel Scraper Module - Simultaneous multi-bracket scraping

Runs multiple bracket/pool scans concurrently using asyncio.gather.
Each URL gets its own browser context for true parallel execution.

Part of MultiCourtScore v2
"""

import asyncio
import time
from typing import List, Optional, Tuple
from dataclasses import dataclass, field

from .core import VBLScraperBase, ScanResult, ScraperConfig, logger
from .bracket import BracketScraper
from .pool import PoolScraper


@dataclass
class ParallelScanResult:
    """Aggregated result from parallel scraping"""
    urls_scanned: int = 0
    total_matches: int = 0
    results: List[ScanResult] = field(default_factory=list)
    status: str = "pending"
    error: Optional[str] = None
    duration_seconds: float = 0.0
    
    def to_dict(self) -> dict:
        return {
            "urls_scanned": self.urls_scanned,
            "total_matches": self.total_matches,
            "results": [r.to_dict() for r in self.results],
            "status": self.status,
            "error": self.error,
            "duration_seconds": round(self.duration_seconds, 2)
        }


class ParallelScraper:
    """
    Scrapes multiple VBL URLs simultaneously using parallel browser instances.
    
    Example usage:
        scraper = ParallelScraper(max_concurrent=4)
        results = await scraper.scan_all([
            "https://vbl.com/bracket1",
            "https://vbl.com/bracket2",
            "https://vbl.com/pool1",
            "https://vbl.com/pool2"
        ], username="user", password="pass")
    """
    
    def __init__(
        self,
        max_concurrent: int = 4,
        config: Optional[ScraperConfig] = None
    ):
        """
        Args:
            max_concurrent: Maximum number of simultaneous browser instances
            config: Shared scraper configuration
        """
        self.max_concurrent = max_concurrent
        self.config = config or ScraperConfig()
        
    def _detect_scraper_type(self, url: str) -> type:
        """Determine which scraper class to use based on URL"""
        url_lower = url.lower()
        if "pool" in url_lower or "/pools/" in url_lower:
            return PoolScraper
        return BracketScraper
    
    async def _scan_single(
        self,
        url: str,
        username: Optional[str],
        password: Optional[str],
        index: int
    ) -> ScanResult:
        """Scan a single URL with its own browser instance"""
        scraper_class = self._detect_scraper_type(url)
        scraper = scraper_class(config=self.config)
        
        logger.info(f"[Worker {index}] Starting scan: {url[:60]}...")
        
        try:
            async with scraper:
                result = await scraper.scan(url, username, password)
                logger.info(
                    f"[Worker {index}] Complete: {result.total_matches} matches "
                    f"from {url[:40]}..."
                )
                return result
        except Exception as e:
            logger.error(f"[Worker {index}] Error scanning {url}: {e}")
            return ScanResult(
                url=url,
                status="error",
                error=str(e)
            )
    
    async def scan_all(
        self,
        urls: List[str],
        username: Optional[str] = None,
        password: Optional[str] = None
    ) -> ParallelScanResult:
        """
        Scan multiple URLs in parallel.
        
        Args:
            urls: List of VBL bracket/pool URLs to scan
            username: VBL username for login (shared across all)
            password: VBL password for login
            
        Returns:
            ParallelScanResult with aggregated results
        """
        if not urls:
            return ParallelScanResult(status="success")
        
        start_time = time.time()
        result = ParallelScanResult()
        result.urls_scanned = len(urls)
        
        logger.info(f"Starting parallel scan of {len(urls)} URLs with max {self.max_concurrent} workers")
        
        try:
            # Create semaphore to limit concurrent browsers
            semaphore = asyncio.Semaphore(self.max_concurrent)
            
            async def scan_with_semaphore(url: str, index: int) -> ScanResult:
                async with semaphore:
                    return await self._scan_single(url, username, password, index)
            
            # Launch all scans concurrently (semaphore limits actual parallelism)
            tasks = [
                scan_with_semaphore(url, i) 
                for i, url in enumerate(urls, 1)
            ]
            
            # Wait for all to complete
            results = await asyncio.gather(*tasks, return_exceptions=True)
            
            # Process results
            for r in results:
                if isinstance(r, Exception):
                    logger.error(f"Task exception: {r}")
                    result.results.append(ScanResult(
                        url="unknown",
                        status="error",
                        error=str(r)
                    ))
                elif isinstance(r, ScanResult):
                    result.results.append(r)
                    result.total_matches += r.total_matches
            
            result.status = "success"
            
        except Exception as e:
            logger.error(f"Parallel scan failed: {e}")
            result.status = "error"
            result.error = str(e)
        
        result.duration_seconds = time.time() - start_time
        logger.info(
            f"Parallel scan complete: {result.total_matches} total matches "
            f"from {result.urls_scanned} URLs in {result.duration_seconds:.1f}s"
        )
        
        return result


async def scan_parallel(
    urls: List[str],
    username: Optional[str] = None,
    password: Optional[str] = None,
    max_concurrent: int = 4,
    headless: bool = True
) -> ParallelScanResult:
    """
    Convenience function for parallel scanning.
    
    Example:
        result = await scan_parallel([
            "https://vbl.com/bracket1",
            "https://vbl.com/bracket2"
        ], username="user", password="pass")
    """
    config = ScraperConfig(headless=headless)
    scraper = ParallelScraper(max_concurrent=max_concurrent, config=config)
    return await scraper.scan_all(urls, username, password)


# CLI interface for testing
if __name__ == "__main__":
    import sys
    import json
    
    async def main():
        if len(sys.argv) < 2:
            print("Usage: python -m vbl_scraper.parallel <url1> <url2> ...")
            print("       Set VBL_USER and VBL_PASS env vars for login")
            sys.exit(1)
        
        import os
        urls = sys.argv[1:]
        username = os.environ.get("VBL_USER")
        password = os.environ.get("VBL_PASS")
        
        result = await scan_parallel(
            urls,
            username=username,
            password=password,
            max_concurrent=4,
            headless=True
        )
        
        print(json.dumps(result.to_dict(), indent=2))
    
    asyncio.run(main())
