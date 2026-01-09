#!/usr/bin/env python3
"""
Bracket Scraper Module - Based on proven v1 three-phase approach
Extracts match data including team names, times, courts, and API URLs

Part of MultiCourtScore v2
"""

import asyncio
import re
from datetime import datetime
from typing import List, Optional, Dict

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
    Uses proven three-phase workflow from v1:
      Phase 1: Find all match containers
      Phase 2: Click each container to open match card overlay
      Phase 3: Extract match data and API URL from overlay
    """
    
    async def scan(
        self, 
        url: str, 
        username: str = None, 
        password: str = None
    ) -> ScanResult:
        """
        Scan a bracket URL and extract all match data.
        """
        result = ScanResult(url=url)
        match_type, type_detail = self.determine_url_type(url)
        result.match_type = match_type
        result.type_detail = type_detail
        
        try:
            logger.info(f"Scanning bracket: {url}")
            await self.page.goto(url, wait_until='networkidle')
            
            # Check if login is needed
            if await self._requires_login():
                if username and password:
                    logger.info("Login required, attempting authentication...")
                    if await self.login(username, password):
                        await self.page.goto(url, wait_until='networkidle')
                    else:
                        result.status = "error"
                        result.error = "Login failed"
                        return result
                else:
                    result.status = "error"
                    result.error = "Login required but no credentials provided"
                    return result
            
            # Wait for bracket to fully load (VBL is slow)
            logger.info("Waiting for bracket content...")
            await asyncio.sleep(4.0)
            
            # Phase 1: Find match containers
            containers = await self._phase1_find_containers()
            logger.info(f"Found {len(containers)} match containers")
            
            if not containers:
                result.status = "success"
                result.error = "No matches found on page"
                return result
            
            # Extract match format info (applies to all matches in this bracket/pool)
            match_format = await self.extract_match_format()
            logger.info(f"Match format: {match_format.get('format_text', 'Not found')}")
            
            # Process each match
            for i, container in enumerate(containers):
                try:
                    logger.info(f"Processing match {i+1}/{len(containers)}...")
                    
                    # Phase 2 & 3: Open card, extract data, get API URL
                    match = await self._process_match(container, i)
                    
                    if match:
                        # Apply format values to match
                        match.sets_to_win = match_format['sets_to_win']
                        match.points_per_set = match_format['points_per_set']
                        match.point_cap = match_format['point_cap']
                        match.format_text = match_format['format_text']
                        
                        result.matches.append(match)
                        team_info = f"{match.team1} vs {match.team2}" if match.team1 else f"Match {i+1}"
                        api_status = "✓ API" if match.api_url else "✗ No API"
                        logger.info(f"  [{i+1}] {team_info} - {api_status}")

                    
                    # Close overlay and pause
                    await self._close_overlay()
                    await asyncio.sleep(0.5)
                    
                except Exception as e:
                    logger.warning(f"  [{i+1}] Error: {e}")
                    await self._close_overlay()
                    continue
            
            result.status = "success"
            logger.info(f"Scan complete: {len(result.matches)} matches extracted")
            
        except Exception as e:
            result.status = "error"
            result.error = str(e)
            logger.error(f"Bracket scan failed: {e}")
        
        return result
    
    async def _requires_login(self) -> bool:
        """Check if login is needed"""
        try:
            return await self.page.is_visible('button:has-text("Sign In")')
        except Exception:
            return False
    
    async def _phase1_find_containers(self) -> List:
        """Find all match containers on the bracket page"""
        logger.info("Phase 1: Finding match containers...")
        
        # VBL-specific selectors that work
        selectors = [
            'div.div-match-card',
            '.match-card',
            '.div-match-card',
            'div[class*="match-card"]',
            '[class*="match"]'
        ]
        
        containers = []
        
        for selector in selectors:
            try:
                await asyncio.sleep(0.5)
                elements = await self.page.locator(selector).all()
                logger.info(f"  Trying {selector}: found {len(elements)} elements")
                
                if elements:
                    for el in elements:
                        try:
                            if not await el.is_visible():
                                continue
                            
                            # Skip left sidebar items (x < 200px)
                            box = await el.bounding_box()
                            if box and box['x'] < 200:
                                continue
                            
                            text = await el.text_content() or ""
                            if len(text.strip()) > 5:  # Has content
                                containers.append(el)
                        except Exception:
                            continue
                    
                    if containers:
                        break
                        
            except Exception as e:
                logger.debug(f"  Selector {selector} failed: {e}")
                continue
        
        return containers
    
    async def _process_match(self, container, index: int) -> Optional[VBLMatch]:
        """Phase 2 & 3: Open match card and extract all data"""
        match = VBLMatch(index=index)
        
        try:
            # Click to open overlay
            logger.debug(f"Clicking match container {index}...")
            await container.click()
            await asyncio.sleep(0.5)
            
            # Wait for overlay with shorter timeout
            try:
                await self.page.wait_for_selector('div.v-overlay-container', timeout=3000)
                
                # Find the overlay that contains a card (not tooltips)
                # Look for an overlay with v-card inside it
                all_overlays = await self.page.locator('div.v-overlay-container').all()
                overlay = None
                
                for ov in all_overlays:
                    # Check if this overlay contains a v-card
                    card_count = await ov.locator('div.v-card').count()
                    if card_count > 0 and await ov.is_visible():
                        overlay = ov
                        logger.debug(f"Found card overlay ({card_count} cards)")
                        break
                
                if not overlay:
                    logger.warning(f"Match {index}: No card overlay found")
                    logger.info(f"Match {index}: Attempting direct extraction from container...")
                    match = await self._extract_from_container(container, match)
                else:
                    # Extract data from card
                    match = await self._extract_card_data(overlay, match)
                    
                    # Extract API URL
                    api_url = await self._extract_api_url()
                    match.api_url = api_url
                
            except Exception as overlay_error:
                logger.warning(f"Match {index}: Failed to open overlay - {type(overlay_error).__name__}: {overlay_error}")
                # Try to extract data directly from container as fallback
                logger.info(f"Match {index}: Attempting direct extraction from container...")
                match = await self._extract_from_container(container, match)
            
        except Exception as e:
            logger.warning(f"Match {index}: Error processing - {type(e).__name__}: {e}")
        
        return match


    
    async def _extract_card_data(self, overlay, match: VBLMatch) -> VBLMatch:
        """Extract match info from the card overlay using specific selectors"""
        try:
            # --- Header Extraction (Match #, Time, Court) ---
            title = overlay.locator('div.v-card-title').first
            if await title.is_visible():
                # Extract Match Number
                # Usually: <span ...>Match 1</span>
                match_span = title.locator('span').first
                if await match_span.is_visible():
                    match_text = await match_span.text_content() or ""
                    m = re.search(r'Match\s*(\d+)', match_text, re.I)
                    if m:
                        match.match_number = m.group(1)
                
                # Extract Time
                # Usually: <div class="text-center">3:15PM</div>
                time_div = title.locator('div.text-center').first
                if await time_div.is_visible():
                    match.start_time = await time_div.text_content()
                
                # Extract Court
                # Usually: <span ...> Court 1</span> (last span)
                # But careful, first span is Match #.
                spans = await title.locator('span').all()
                if len(spans) > 1:
                    court_span = spans[-1]
                    court_text = await court_span.text_content() or ""
                    m = re.search(r'(?:Court|Ct)\s*(\d+|[A-Z0-9]+)', court_text, re.I)
                    if m:
                        match.court = m.group(1)
            
            # --- Team & Seed Extraction ---
            # Structure: Table > tbody > tr > td (outer) > table > tbody > tr > td (seed) + td (name)
            
            # We can find all rows in the inner tables.
            # Locating all 'td.clickable' gives us the name cells.
            # The seed cell is usually the 'td' immediately preceding it in that row, 
            # or we can look for 'td.d-flex.align-center.justify-center'.
            
            name_cells = await overlay.locator('td.clickable').all()
            seed_cells = await overlay.locator('td.d-flex.align-center.justify-center').all()
            
            logger.debug(f"Found {len(name_cells)} name cells and {len(seed_cells)} seed cells")
            
            # If no cells found, dump overlay HTML for debugging
            if len(name_cells) == 0:
                overlay_html = await overlay.inner_html()
                logger.debug(f"Overlay HTML (first 500 chars): {overlay_html[:500]}")
            
            teams = []
            
            # Process found cells
            # Note: We take up to 2. VBL bracket matches have 2 teams.
            count = min(len(name_cells), 2)
            
            for i in range(count):
                # Name
                name_cell = name_cells[i]
                name = await name_cell.text_content() or ""
                name = name.strip()
                
                # Seed (optional)
                seed = None
                if i < len(seed_cells):
                    seed_text = await seed_cells[i].text_content() or ""
                    seed_text = seed_text.strip()
                    if seed_text.isdigit():
                        seed = seed_text
                
                teams.append((seed, name))

            # Score Extraction
            # Scores are typically in TDs that contain only digits
            # usually after the name cell in the same row
            score_cells = await overlay.locator('td.text-center').all()
            scores = []
            
            # Simple heuristic: look for cells with just numbers
            for cell in score_cells:
                text = await cell.text_content() or ""
                text = text.strip()
                if text.isdigit():
                    scores.append(int(text))
            
            # If we found at least 2 scores, assume they correspond to team 1 and team 2
            if len(scores) >= 2:
                # Assuming top row is team 1, bottom row is team 2
                match.team1_score = scores[0]
                match.team2_score = scores[1]
                logger.debug(f"Extracted scores: {match.team1_score} - {match.team2_score}")
            
            # Assign to match object
            if len(teams) >= 2:
                match.team1_seed = teams[0][0]
                match.team1 = teams[0][1]
                match.team2_seed = teams[1][0]
                match.team2 = teams[1][1]
            elif len(teams) == 1:
                match.team1_seed = teams[0][0]
                match.team1 = teams[0][1]
                
            # Fallback patterns: Look for descriptive placeholders like "Match X Winner" or "Winner Match X"
            # Only override if we got actual "TBD" or empty string
            if not match.team1 or match.team1.strip().upper() == "TBD" or match.team1.strip() == "":
                full_text = await overlay.text_content() or ""
                # Look for "Match X Winner" or "Winner of Match X"
                placeholders = re.findall(r'((?:Match\s+\d+|Winner|Loser)(?:\s+of)?\s+(?:Match\s+\d+|Winner|Loser)?)', full_text, re.I)
                if len(placeholders) >= 1:
                    # Clean up found placeholders
                    valid = [p.strip() for p in placeholders if len(p.strip()) > 5]
                    if len(valid) >= 2:
                        match.team1 = valid[0]

                        match.team2 = valid[1]
                    elif len(valid) == 1:
                        # If we only found one, and team1 was generic, assign it to team1
                        if not match.team1 or match.team1.lower() in ["team a", "team b", "tbd"]:
                            match.team1 = valid[0]
                        elif not match.team2 or match.team2.lower() in ["team a", "team b", "tbd"]:
                            match.team2 = valid[0]
                    
        except Exception as e:
            logger.debug(f"Error extracting card data: {e}")
            
        return match
    
    async def _extract_from_container(self, container, match: VBLMatch) -> VBLMatch:
        """
        Fallback: Extract data directly from match container when overlay doesn't open.
        This handles matches that are displayed directly on the bracket without clickable overlays.
        """
        try:
            # Get all text content from the container
            text_content = await container.text_content() or ""
            logger.debug(f"Container text: {text_content[:200]}")
            
            # Try to extract team names using regex pattern
            # Look for "Name / Name" pattern (team pairs)
            team_pattern = r'([A-Z][a-z]+(?:\s+[A-Z][a-z]+)*)\s*/\s*([A-Z][a-z]+(?:\s+[A-Z][a-z]+)*)'
            team_matches = re.findall(team_pattern, text_content)
            
            if len(team_matches) >= 2:
                # Each match is a tuple of (firstname, lastname) for one player
                # Team 1: match[0] + match[1]
                # Team 2: match[2] + match[3]
                match.team1 = f"{team_matches[0][0]} / {team_matches[0][1]}"
                match.team2 = f"{team_matches[1][0]} / {team_matches[1][1]}"
                
                # Clean up common suffixes
                match.team2 = re.sub(r'\s+Ref.*$', '', match.team2)
                
                logger.info(f"Extracted teams: {match.team1} vs {match.team2}")

            
            # Extract time (look for patterns like "9:00AM", "10:30 AM")
            time_match = re.search(r'(\d{1,2}:\d{2}\s*(?:AM|PM))', text_content, re.IGNORECASE)
            if time_match:
                match.start_time = time_match.group(1).replace(" ", "")
                logger.info(f"Extracted time: {match.start_time}")
            
            # Extract court number - look for single digit after "Court:"
            court_match = re.search(r'Court[:\s]*(\d)', text_content, re.IGNORECASE)
            if court_match:
                match.court = court_match.group(1)
                logger.info(f"Extracted court: {match.court}")
            
        except Exception as e:
            logger.warning(f"Error in fallback extraction: {e}")
        
        return match
    
    async def _extract_api_url(self) -> Optional[str]:

        """Click vMix button and extract API URL"""
        try:
            # Find and click vMix button
            vmix_selectors = [
                'button:has-text("VMIX")',
                'button:has-text("Vmix")',
                'button:has-text("vMix")'
            ]
            
            vmix_clicked = False
            for selector in vmix_selectors:
                try:
                    buttons = await self.page.locator(selector).all()
                    for btn in buttons:
                        if await btn.is_visible() and await btn.is_enabled():
                            text = await btn.text_content() or ""
                            if 'vmix' in text.lower():
                                await btn.click(force=True)
                                vmix_clicked = True
                                break
                    if vmix_clicked:
                        break
                except Exception:
                    continue
            
            if not vmix_clicked:
                logger.debug("vMix button not found")
                return None
            
            # Wait for API URL to appear
            # Increased wait time to 3.0s to ensure overlay loads
            await asyncio.sleep(3.0)
            
            # Method 1: Look for API URL in page content
            content = await self.page.content()
            api_patterns = [
                r'(https://api\.volleyballlife\.com/api/v1\.0/matches/\d+/vmix\?bracket=true)',
                r'(https://api\.volleyballlife\.com/api/v1\.0/matches/\d+/vmix[^"\s<]+)',
            ]
            
            for pattern in api_patterns:
                matches = re.findall(pattern, content, re.I)
                if matches:
                    # Clean up the URL (remove any trailing junk)
                    url = matches[0].split()[0].split('<')[0].strip()
                    logger.info(f"FOUND API URL (content): {url}")
                    return url
            
            # Method 2: Look for links
            links = await self.page.locator('a[href*="api.volleyballlife.com"]').all()
            for link in links:
                if await link.is_visible():
                    href = await link.get_attribute('href')
                    if href and 'vmix' in href:
                        logger.info(f"FOUND API URL (link): {href}")
                        return href
            
            # Method 3: Check inputs
            inputs = await self.page.locator('input').all()
            for inp in inputs:
                try:
                    val = await inp.get_attribute('value') or ""
                    if 'api.volleyballlife.com' in val:
                        logger.info(f"FOUND API URL (input): {val}")
                        return val
                except Exception:
                    continue
            
            logger.warning("FAILED to find API URL after clicking vMix button")
            return None
            
        except Exception as e:
            logger.debug(f"Error extracting API URL: {e}")
            return None
    
    async def _close_overlay(self):
        """Close any open overlay"""
        try:
            # Try clicking scrim/backdrop first
            try:
                scrim = self.page.locator('.v-overlay__scrim').first
                if await scrim.is_visible():
                    # Click on the scrim but avoid the overlay content
                    box = await scrim.bounding_box()
                    if box:
                        # Click at the edge of the scrim
                        await self.page.mouse.click(box['x'] + 10, box['y'] + 10)
                        await asyncio.sleep(0.2)
                        return
            except Exception:
                pass
            
            # Fallback: press Escape
            await self.page.keyboard.press('Escape')
            await asyncio.sleep(0.3)
            
        except Exception:
            pass
