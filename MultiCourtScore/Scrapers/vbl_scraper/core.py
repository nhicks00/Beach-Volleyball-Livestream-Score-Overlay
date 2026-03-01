#!/usr/bin/env python3
"""
VBL Scraper Core - Data models and utilities
VolleyballLife match data structures

Part of MultiCourtScore v2 - API-only architecture
"""

import json
import logging
import os
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import List, Optional, Dict, Any

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(name)s: %(message)s',
    datefmt='%H:%M:%S'
)
logger = logging.getLogger('vbl_scraper')


@dataclass
class VBLMatch:
    """Represents a single match from VBL"""
    index: int
    match_number: Optional[str] = None
    team1: Optional[str] = None
    team2: Optional[str] = None
    team1_seed: Optional[str] = None  # e.g., "1", "2", "3"
    team2_seed: Optional[str] = None
    court: Optional[str] = None
    start_time: Optional[str] = None
    start_date: Optional[str] = None  # Day abbreviation (Sat, Sun, etc.)
    api_url: Optional[str] = None
    match_type: Optional[str] = None
    type_detail: Optional[str] = None
    # Match format fields
    sets_to_win: int = 2  # Default to best-of-3 (2 sets to win)
    points_per_set: int = 21  # Points needed to win a set
    point_cap: Optional[int] = None  # Point cap (e.g., 23), None means win by 2
    format_text: Optional[str] = None  # Raw format text from page
    # Initial scores (if match is already live)
    team1_score: int = 0
    team2_score: int = 0

    def to_dict(self) -> Dict[str, Any]:
        return {
            'index': self.index,
            'match_number': self.match_number,
            'team1': self.team1,
            'team2': self.team2,
            'team1_seed': self.team1_seed,
            'team2_seed': self.team2_seed,
            'court': self.court,
            'startTime': self.start_time,
            'startDate': self.start_date,
            'api_url': self.api_url,
            'match_type': self.match_type,
            'type_detail': self.type_detail,
            'setsToWin': self.sets_to_win,
            'pointsPerSet': self.points_per_set,
            'pointCap': self.point_cap,
            'formatText': self.format_text,
            'team1_score': self.team1_score,
            'team2_score': self.team2_score
        }


@dataclass
class ScanResult:
    """Result of scanning a VBL URL"""
    url: str
    matches: List[VBLMatch] = field(default_factory=list)
    status: str = "pending"
    error: Optional[str] = None
    timestamp: str = field(default_factory=lambda: datetime.now().isoformat())
    match_type: Optional[str] = None
    type_detail: Optional[str] = None

    @property
    def total_matches(self) -> int:
        return len(self.matches)

    def to_dict(self) -> Dict[str, Any]:
        return {
            'url': self.url,
            'timestamp': self.timestamp,
            'total_matches': self.total_matches,
            'matches': [m.to_dict() for m in self.matches],
            'status': self.status,
            'error': self.error,
            'match_type': self.match_type,
            'type_detail': self.type_detail
        }
