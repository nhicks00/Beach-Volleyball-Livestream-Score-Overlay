"""
VBL Format Text Parser

Parses VBL format text strings into structured match format values.

Examples:
- "All matches are 1 game to 28 with no cap" → setsToWin=1, pointsPerSet=28, pointCap=None
- "All Matches Are Match Play (best 2 out of 3). Sets 1 & 2 to 21 with no cap & set 3 to 15 with no cap" 
    → setsToWin=2, pointsPerSet=21, pointCap=None
- "All matches are 1 game to 21 cap at 23" → setsToWin=1, pointsPerSet=21, pointCap=23
"""

import re
from typing import Optional, Dict, Any
import logging

logger = logging.getLogger('vbl_scraper.parse_format')


def parse_format_text(text: str) -> Dict[str, Any]:
    """
    Parse VBL format text into structured values.
    
    Args:
        text: Raw format text from VBL page (e.g., "All matches are 1 game to 28 with no cap")
    
    Returns:
        dict with keys:
            - sets_to_win: int (1, 2, or 3)
            - points_per_set: int (typically 21, 25, 28, 15)
            - point_cap: int or None (None means "no cap" / win by 2)
    """
    if not text:
        return _defaults()
    
    text_lower = text.lower().strip()
    
    result = {
        'sets_to_win': _parse_sets_to_win(text_lower),
        'points_per_set': _parse_points_per_set(text_lower),
        'point_cap': _parse_point_cap(text_lower),
    }
    
    logger.info(f"Parsed format text: '{text[:50]}...' → {result}")
    return result


def _defaults() -> Dict[str, Any]:
    """Default values when no format text is provided."""
    return {
        'sets_to_win': 2,
        'points_per_set': 21,
        'point_cap': None,
    }


def _parse_sets_to_win(text: str) -> int:
    """
    Determine number of sets to win.
    
    Patterns:
    - "1 game" → 1 set to win
    - "best 2 out of 3" or "match play" → 2 sets to win
    - "best 3 out of 5" → 3 sets to win
    """
    # Single game format
    if re.search(r'\b1\s*game\b', text):
        return 1
    
    # Match play / best of 3
    if re.search(r'match\s*play', text):
        return 2
    
    # "best X out of Y" pattern
    best_of_match = re.search(r'best\s+(\d+)\s+out\s+of\s+(\d+)', text)
    if best_of_match:
        sets_to_win = int(best_of_match.group(1))
        return sets_to_win
    
    # "best of 3" or "best of 5" pattern
    best_of_short = re.search(r'best\s+of\s+(\d+)', text)
    if best_of_short:
        total_sets = int(best_of_short.group(1))
        # Best of 3 = 2 to win, best of 5 = 3 to win
        return (total_sets // 2) + 1
    
    # "2 sets" or "3 sets" patterns
    sets_match = re.search(r'(\d+)\s+set', text)
    if sets_match:
        # If it says "2 sets" it means 2 sets to win
        # But if it's describing total sets, calculate accordingly
        num = int(sets_match.group(1))
        if num <= 3:
            return num if num <= 2 else 2
    
    # Default: best of 3 (2 sets to win)
    return 2


def _parse_points_per_set(text: str) -> int:
    """
    Determine points per set.
    
    Patterns:
    - "to 21" or "game to 21"
    - "sets 1 & 2 to 21" (use first set's points as default)
    - "to 28", "to 25", "to 15"
    """
    # Pattern: "game to X" or "to X"
    game_to = re.search(r'(?:game|games?)\s+to\s+(\d+)', text)
    if game_to:
        return int(game_to.group(1))
    
    # Pattern: "sets 1 & 2 to X" (match play format)
    sets_to = re.search(r'sets?\s+\d+\s*(?:&|and)\s*\d+\s+to\s+(\d+)', text)
    if sets_to:
        return int(sets_to.group(1))
    
    # Pattern: "set 1 to X" or "set to X"
    set_to = re.search(r'set\s*\d*\s+to\s+(\d+)', text)
    if set_to:
        return int(set_to.group(1))
    
    # Generic "to X" near start of string or after common keywords
    to_points = re.search(r'\bto\s+(\d+)\b', text)
    if to_points:
        points = int(to_points.group(1))
        # Sanity check: volleyball scores are typically 15, 21, 25, 28
        if 10 <= points <= 35:
            return points
    
    # Look for standalone numbers that make sense as point values
    numbers = re.findall(r'\b(\d{2})\b', text)
    for num_str in numbers:
        num = int(num_str)
        if num in [15, 21, 25, 28]:
            return num
    
    # Default: 21 points
    return 21


def _parse_point_cap(text: str) -> Optional[int]:
    """
    Determine point cap.
    
    Patterns:
    - "no cap" or "with no cap" → None (win by 2)
    - "cap at 23" or "capped at 23" → 23
    - "cap 30" → 30
    """
    # Check for "no cap" first
    if re.search(r'\bno\s*cap\b', text):
        return None
    
    # Pattern: "cap at X" or "capped at X"
    cap_at = re.search(r'cap(?:ped)?\s+(?:at\s+)?(\d+)', text)
    if cap_at:
        return int(cap_at.group(1))
    
    # Pattern: "win by 2" implies no cap
    if re.search(r'win\s+by\s+2', text):
        return None
    
    # Default: no cap
    return None


# Convenience function for testing
if __name__ == '__main__':
    test_cases = [
        "All matches are 1 game to 28 with no cap",
        "All Matches Are Match Play (best 2 out of 3). Sets 1 & 2 to 21 with no cap & set 3 to 15 with no cap",
        "All matches are 1 game to 21 cap at 23",
        "Best of 3 sets to 25",
        "1 Game to 25",
        "1 game to 21, win by 2",
        "Match Play to 21",
        "",
        None,
    ]
    
    for tc in test_cases:
        result = parse_format_text(tc or "")
        print(f"'{tc}' → {result}")
