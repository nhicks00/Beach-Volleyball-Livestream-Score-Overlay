"""
VBL Scraper Package
Consolidated scraper for VolleyballLife bracket and pool data

Part of MultiCourtScore v2
"""

from .core import VBLScraperBase, VBLMatch, ScanResult, ScraperConfig
from .bracket import BracketScraper
from .pool import PoolScraper
from .parallel import ParallelScraper, ParallelScanResult, scan_parallel

__version__ = "2.1.0"
__all__ = [
    'VBLScraperBase',
    'VBLMatch',
    'ScanResult', 
    'ScraperConfig',
    'BracketScraper',
    'PoolScraper',
    'ParallelScraper',
    'ParallelScanResult',
    'scan_parallel'
]
