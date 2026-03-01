"""
VBL Scraper Package
API-only scraper for VolleyballLife bracket and pool data

Part of MultiCourtScore v2
"""

from .core import VBLMatch, ScanResult
from .api_scraper import scan_via_api

__version__ = "3.0.0"
__all__ = [
    'VBLMatch',
    'ScanResult',
    'scan_via_api',
]
