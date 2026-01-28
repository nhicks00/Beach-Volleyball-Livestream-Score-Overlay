#!/usr/bin/env python3
"""
Bracket Scraper Module - Optimized for speed
Extracts match data including team names, times, courts, and API URLs

OPTIMIZATIONS:
- Two-phase approach: Extract all match data first, then batch API URLs
- Reduced wait times with smarter selectors
- Skip API extraction for TBD/incomplete matches
- Parallel processing of match cards within a bracket

Part of MultiCourtScore v2
"""

import asyncio
import re
from datetime import datetime
from typing import List, Optional, Dict, Tuple

from playwright.async_api import TimeoutError as PlaywrightTimeout

from .core import (
    VBLScraperBase,
    VBLMatch,
    ScanResult,
    ScraperConfig,
    logger
)


class BracketScraper(VBLScraperBase):
    """
    Scraper for VolleyballLife bracket pages.

    Optimized two-phase workflow:
      Phase 1: Find all match containers and extract basic data (fast)
      Phase 2: Batch extract API URLs only for matches with real teams
    """

    # Day abbreviations to look for in time strings
    DAY_PATTERNS = [
        ('saturday', 'Sat'), ('sunday', 'Sun'), ('friday', 'Fri'),
        ('thursday', 'Thu'), ('wednesday', 'Wed'), ('tuesday', 'Tue'), ('monday', 'Mon'),
        ('sat', 'Sat'), ('sun', 'Sun'), ('fri', 'Fri'),
        ('thu', 'Thu'), ('wed', 'Wed'), ('tue', 'Tue'), ('mon', 'Mon'),
    ]

    def _parse_day_time(self, raw_text: str) -> tuple:
        """Parse combined day+time string like 'Sat 12:00 PM' into (day, time)."""
        if not raw_text:
            return None, None

        text = raw_text.strip()
        start_date = None
        start_time = None

        text_lower = text.lower()
        for pattern, abbrev in self.DAY_PATTERNS:
            if text_lower.startswith(pattern):
                start_date = abbrev
                text = text[len(pattern):].strip()
                break

        time_match = re.search(r'(\d{1,2}:\d{2}\s*(?:AM|PM))', text, re.IGNORECASE)
        if time_match:
            start_time = time_match.group(1).replace(' ', '')

        return start_date, start_time

    def _has_real_teams(self, match: VBLMatch) -> bool:
        """Check if match has real team names (not TBD/placeholder)"""
        placeholders = ['tbd', 'team a', 'team b', 'winner', 'loser', 'match']

        def is_placeholder(name: str) -> bool:
            if not name:
                return True
            name_lower = name.lower().strip()
            return any(p in name_lower for p in placeholders) or len(name_lower) < 3

        return not is_placeholder(match.team1) and not is_placeholder(match.team2)

    async def scan(
        self,
        url: str,
        username: str = None,
        password: str = None
    ) -> ScanResult:
        """Scan a bracket URL with optimized speed."""
        result = ScanResult(url=url)
        match_type, type_detail = self.determine_url_type(url)
        result.match_type = match_type
        result.type_detail = type_detail

        try:
            logger.info(f"Scanning bracket: {url}")
            # Use domcontentloaded instead of networkidle for faster initial load
            await self.page.goto(url, wait_until='domcontentloaded')

            # Check if login is needed
            if await self._requires_login():
                if username and password:
                    logger.info("Login required, attempting authentication...")
                    if await self.login(username, password):
                        await self.page.goto(url, wait_until='domcontentloaded')
                    else:
                        result.status = "error"
                        result.error = "Login failed"
                        return result
                else:
                    result.status = "error"
                    result.error = "Login required but no credentials provided"
                    return result

            # Wait for bracket content - reduced from 4s to 2s
            logger.info("Waiting for bracket content...")
            await asyncio.sleep(2.0)

            # Phase 1: Find match containers
            containers = await self._phase1_find_containers()
            logger.info(f"Found {len(containers)} match containers")

            if not containers:
                result.status = "success"
                result.error = "No matches found on page"
                return result

            # Extract match format info (applies to all matches)
            match_format = await self.extract_match_format()
            logger.info(f"Match format: {match_format.get('format_text', 'Not found')}")

            # PHASE 1: Extract all match data quickly (no API URLs yet)
            logger.info("Phase 1: Extracting match data...")
            matches_to_process = []

            for i, container in enumerate(containers):
                try:
                    match = await self._extract_match_data_fast(container, i)
                    if match:
                        match.sets_to_win = match_format['sets_to_win']
                        match.points_per_set = match_format['points_per_set']
                        match.point_cap = match_format['point_cap']
                        match.format_text = match_format['format_text']
                        matches_to_process.append((i, container, match))

                        team_info = f"{match.team1} vs {match.team2}" if match.team1 else f"Match {i+1}"
                        logger.info(f"  [{i+1}] {team_info}")
                except Exception as e:
                    logger.warning(f"  [{i+1}] Error: {e}")
                    continue

            # PHASE 2: Batch extract API URLs only for matches with real teams
            logger.info("Phase 2: Extracting API URLs for complete matches...")
            matches_needing_api = [(i, c, m) for i, c, m in matches_to_process if self._has_real_teams(m)]
            matches_with_tbd = [(i, c, m) for i, c, m in matches_to_process if not self._has_real_teams(m)]

            logger.info(f"  {len(matches_needing_api)} matches need API URLs, {len(matches_with_tbd)} are TBD/incomplete")

            # Process API URLs in batches for speed
            for i, container, match in matches_needing_api:
                try:
                    api_url = await self._extract_api_url_for_match(container, i)
                    match.api_url = api_url
                    api_status = "✓ API" if api_url else "✗ No API"
                    logger.info(f"  [{i+1}] {api_status}")
                except Exception as e:
                    logger.warning(f"  [{i+1}] API extraction error: {e}")

            # Add all matches to result
            for _, _, match in matches_to_process:
                result.matches.append(match)

            result.status = "success"
            logger.info(f"Scan complete: {len(result.matches)} matches ({len(matches_needing_api)} with API URLs)")

        except Exception as e:
            result.status = "error"
            result.error = str(e)
            logger.error(f"Bracket scan failed: {e}")

        return result

    async def _requires_login(self) -> bool:
        """Check if login is needed"""
        try:
            return await self.page.is_visible('button:has-text("Sign In")', timeout=1000)
        except Exception:
            return False

    async def _phase1_find_containers(self) -> List:
        """Find all match containers on the bracket page"""
        logger.info("Finding match containers...")

        selectors = [
            'div.div-match-card',
            '.match-card',
            '.div-match-card',
            'div[class*="match-card"]',
        ]

        containers = []

        for selector in selectors:
            try:
                elements = await self.page.locator(selector).all()

                if elements:
                    for el in elements:
                        try:
                            if not await el.is_visible():
                                continue

                            box = await el.bounding_box()
                            if box and box['x'] < 200:
                                continue

                            text = await el.text_content() or ""
                            if len(text.strip()) > 5:
                                containers.append(el)
                        except Exception:
                            continue

                    if containers:
                        break

            except Exception as e:
                logger.debug(f"Selector {selector} failed: {e}")
                continue

        return containers

    async def _extract_match_data_fast(self, container, index: int) -> Optional[VBLMatch]:
        """Extract match data without API URL (fast path)"""
        match = VBLMatch(index=index)

        try:
            # Extract day+time from bracket label BEFORE clicking
            try:
                label = container.locator('.bracket-label, .topx, [class*="bracket-label"]').first
                if await label.is_visible():
                    spans = await label.locator('span').all()
                    if len(spans) >= 2:
                        day_time_text = await spans[1].text_content()
                        if day_time_text:
                            match.start_date, match.start_time = self._parse_day_time(day_time_text)
            except Exception:
                pass

            # Click to open overlay
            await container.click()
            await asyncio.sleep(0.3)  # Reduced from 0.5s

            # Wait for overlay with shorter timeout
            try:
                await self.page.wait_for_selector('div.v-overlay-container', timeout=2000)  # Reduced from 3000

                all_overlays = await self.page.locator('div.v-overlay-container').all()
                overlay = None

                for ov in all_overlays:
                    card_count = await ov.locator('div.v-card').count()
                    if card_count > 0 and await ov.is_visible():
                        overlay = ov
                        break

                if overlay:
                    match = await self._extract_card_data(overlay, match)
                else:
                    match = await self._extract_from_container(container, match)

            except Exception:
                match = await self._extract_from_container(container, match)

            # Close overlay quickly
            await self._close_overlay_fast()

        except Exception as e:
            logger.debug(f"Match {index}: Error - {e}")

        return match

    async def _extract_api_url_for_match(self, container, index: int) -> Optional[str]:
        """Extract API URL for a specific match"""
        try:
            # Click to open overlay
            await container.click()
            await asyncio.sleep(0.3)

            # Wait for overlay
            try:
                await self.page.wait_for_selector('div.v-overlay-container', timeout=2000)
            except Exception:
                return None

            # Extract API URL
            api_url = await self._extract_api_url_fast()

            # Close overlay
            await self._close_overlay_fast()

            return api_url

        except Exception as e:
            logger.debug(f"Match {index}: API extraction error - {e}")
            await self._close_overlay_fast()
            return None

    async def _extract_api_url_fast(self) -> Optional[str]:
        """Optimized API URL extraction"""
        try:
            # Find and click vMix button
            vmix_btn = self.page.locator('button:has-text("vMix"), button:has-text("VMIX")').first

            try:
                if await vmix_btn.is_visible(timeout=500):
                    await vmix_btn.click(force=True)
                else:
                    return None
            except Exception:
                return None

            # Reduced wait time from 3s to 1.5s
            await asyncio.sleep(1.5)

            # Quick content scan for API URL
            content = await self.page.content()

            # Single optimized regex
            match = re.search(
                r'(https://api\.volleyballlife\.com/api/v1\.0/matches/\d+/vmix[^"\s<]*)',
                content, re.I
            )

            if match:
                url = match.group(1).split()[0].split('<')[0].strip()
                return url

            # Fallback: check inputs quickly
            inputs = await self.page.locator('input[value*="api.volleyballlife.com"]').all()
            for inp in inputs:
                try:
                    val = await inp.get_attribute('value')
                    if val and 'vmix' in val:
                        return val
                except Exception:
                    continue

            return None

        except Exception as e:
            logger.debug(f"API URL extraction error: {e}")
            return None

    async def _extract_card_data(self, overlay, match: VBLMatch) -> VBLMatch:
        """Extract match info from the card overlay"""
        try:
            # Header Extraction
            title = overlay.locator('div.v-card-title').first
            if await title.is_visible():
                match_span = title.locator('span').first
                if await match_span.is_visible():
                    match_text = await match_span.text_content() or ""
                    m = re.search(r'Match\s*(\d+)', match_text, re.I)
                    if m:
                        match.match_number = m.group(1)

                time_div = title.locator('div.text-center').first
                if await time_div.is_visible():
                    raw_time = await time_div.text_content()
                    overlay_date, overlay_time = self._parse_day_time(raw_time)
                    if overlay_time:
                        match.start_time = overlay_time
                    if overlay_date:
                        match.start_date = overlay_date

                spans = await title.locator('span').all()
                if len(spans) > 1:
                    court_span = spans[-1]
                    court_text = await court_span.text_content() or ""
                    m = re.search(r'(?:Court|Ct)\s*(\d+|[A-Z0-9]+)', court_text, re.I)
                    if m:
                        match.court = m.group(1)

            # Team & Seed Extraction
            name_cells = await overlay.locator('td.clickable').all()
            seed_cells = await overlay.locator('td.d-flex.align-center.justify-center').all()

            teams = []
            count = min(len(name_cells), 2)

            for i in range(count):
                name_cell = name_cells[i]
                name = await name_cell.text_content() or ""
                name = name.strip()

                seed = None
                if i < len(seed_cells):
                    seed_text = await seed_cells[i].text_content() or ""
                    seed_text = seed_text.strip()
                    if seed_text.isdigit():
                        seed = seed_text

                teams.append((seed, name))

            # Score Extraction
            score_cells = await overlay.locator('td.text-center').all()
            scores = []

            for cell in score_cells:
                text = await cell.text_content() or ""
                text = text.strip()
                if text.isdigit():
                    scores.append(int(text))

            if len(scores) >= 2:
                match.team1_score = scores[0]
                match.team2_score = scores[1]

            # Assign teams
            if len(teams) >= 2:
                match.team1_seed = teams[0][0]
                match.team1 = teams[0][1]
                match.team2_seed = teams[1][0]
                match.team2 = teams[1][1]
            elif len(teams) == 1:
                match.team1_seed = teams[0][0]
                match.team1 = teams[0][1]

            # Fallback for placeholder names
            if not match.team1 or match.team1.strip().upper() == "TBD" or match.team1.strip() == "":
                full_text = await overlay.text_content() or ""
                placeholders = re.findall(
                    r'((?:Match\s+\d+|Winner|Loser)(?:\s+of)?\s+(?:Match\s+\d+|Winner|Loser)?)',
                    full_text, re.I
                )
                if len(placeholders) >= 1:
                    valid = [p.strip() for p in placeholders if len(p.strip()) > 5]
                    if len(valid) >= 2:
                        match.team1 = valid[0]
                        match.team2 = valid[1]
                    elif len(valid) == 1:
                        if not match.team1 or match.team1.lower() in ["team a", "team b", "tbd"]:
                            match.team1 = valid[0]
                        elif not match.team2 or match.team2.lower() in ["team a", "team b", "tbd"]:
                            match.team2 = valid[0]

        except Exception as e:
            logger.debug(f"Error extracting card data: {e}")

        return match

    async def _extract_from_container(self, container, match: VBLMatch) -> VBLMatch:
        """Fallback: Extract data directly from match container"""
        try:
            text_content = await container.text_content() or ""

            # Team names
            team_pattern = r'([A-Z][a-z]+(?:\s+[A-Z][a-z]+)*)\s*/\s*([A-Z][a-z]+(?:\s+[A-Z][a-z]+)*)'
            team_matches = re.findall(team_pattern, text_content)

            if len(team_matches) >= 2:
                match.team1 = f"{team_matches[0][0]} / {team_matches[0][1]}"
                match.team2 = f"{team_matches[1][0]} / {team_matches[1][1]}"
                match.team2 = re.sub(r'\s+Ref.*$', '', match.team2)

            # Day + Time
            day_time_match = re.search(
                r'((?:sat|sun|mon|tue|wed|thu|fri)(?:urday|day|nesday|sday)?)?\s*(\d{1,2}:\d{2}\s*(?:AM|PM))',
                text_content,
                re.IGNORECASE
            )
            if day_time_match:
                day_str = day_time_match.group(1)
                time_str = day_time_match.group(2)
                if day_str:
                    match.start_date = day_str[:3].capitalize()
                match.start_time = time_str.replace(" ", "")

            # Court
            court_match = re.search(r'Court[:\s]*(\d)', text_content, re.IGNORECASE)
            if court_match:
                match.court = court_match.group(1)

        except Exception as e:
            logger.warning(f"Error in fallback extraction: {e}")

        return match

    async def _close_overlay_fast(self):
        """Close overlay quickly"""
        try:
            await self.page.keyboard.press('Escape')
            await asyncio.sleep(0.15)  # Reduced from 0.3s
        except Exception:
            pass

    # Keep legacy method for compatibility
    async def _process_match(self, container, index: int) -> Optional[VBLMatch]:
        """Legacy method - redirects to fast path"""
        return await self._extract_match_data_fast(container, index)

    async def _extract_api_url(self) -> Optional[str]:
        """Legacy method - redirects to fast path"""
        return await self._extract_api_url_fast()

    async def _close_overlay(self):
        """Legacy method - redirects to fast path"""
        await self._close_overlay_fast()
