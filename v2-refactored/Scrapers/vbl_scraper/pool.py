#!/usr/bin/env python3
"""
Pool Scraper Module - Updated for VBL React SPA
Uses three-phase approach like bracket scraper to extract API URLs

Part of MultiCourtScore v2
"""

import asyncio
import re
from typing import List, Optional

from playwright.async_api import TimeoutError as PlaywrightTimeout

from .core import (
    VBLScraperBase, 
    VBLMatch, 
    ScanResult, 
    ScraperConfig,
    logger
)


class PoolScraper(VBLScraperBase):
    """
    Scraper for VolleyballLife pool play pages.
    Uses three-phase workflow to extract match data and API URLs.
    """
    
    async def scan(
        self, 
        url: str, 
        username: str = None, 
        password: str = None
    ) -> ScanResult:
        """
        Scan a pool URL and extract all match data.
        """
        result = ScanResult(url=url)
        match_type, type_detail = self.determine_url_type(url)
        result.match_type = match_type
        result.type_detail = type_detail
        
        try:
            logger.info(f"Scanning pool: {url}")
            await self.page.goto(url, wait_until='networkidle')
            
            # Check for login required (session-level tracking prevents multiple logins)
            if await self._requires_login():
                if VBLScraperBase._session_logged_in:
                    logger.info("Session already authenticated - refreshing page")
                    await self.page.goto(url, wait_until='networkidle')
                elif username and password:
                    logger.info("Login required, attempting authentication...")
                    if await self.login(username, password):
                        result.login_performed = True
                        await self.page.goto(url, wait_until='networkidle')
                    else:
                        result.status = "error"
                        result.error = "Login failed"
                        return result
                else:
                    result.status = "error"
                    result.error = "Login required but no credentials provided"
                    return result
            
            # Wait for content to load (VBL React is slow)
            logger.info("Waiting for pool content to load...")
            await asyncio.sleep(4.0)
            
            # Phase 1: Find match containers
            containers = await self._find_match_containers()
            logger.info(f"Found {len(containers)} match containers")
            
            if not containers:
                result.status = "success"
                result.error = "No matches found on page"
                return result
            
            # Extract match format from page (e.g., "2 sets, both to 21")
            match_format = await self.extract_match_format()
            logger.info(f"Match format: {match_format.get('format_text', 'Not found')}")
            
            # Process each match
            for i, container in enumerate(containers):
                try:
                    logger.info(f"Processing match {i+1}/{len(containers)}...")
                    
                    match = await self._process_match(container, i)
                    
                    if match and (match.team1 or match.api_url):
                        # Set match type from URL analysis
                        match.match_type = match_type
                        match.type_detail = type_detail
                        # Apply match format
                        match.sets_to_win = match_format['sets_to_win']
                        match.points_per_set = match_format['points_per_set']
                        match.point_cap = match_format['point_cap']
                        match.format_text = match_format['format_text']
                        result.matches.append(match)
                        team_info = f"{match.team1} vs {match.team2}" if match.team1 else f"Match {i+1}"
                        api_status = "✓ API" if match.api_url else "✗ No API"
                        court_info = f"Court {match.court}" if match.court else "Court TBD"
                        time_info = match.start_time if match.start_time else ""
                        logger.info(f"  [{i+1}] {team_info} - {court_info} {time_info} - {api_status}")
                    
                    # Close any overlay and pause
                    await self._close_overlay()
                    await asyncio.sleep(0.5)
                    
                except Exception as e:
                    logger.warning(f"  [{i+1}] Error: {e}")
                    await self._close_overlay()
                    continue
            
            # Deduplicate matches by team signature
            unique_matches = []
            seen_signatures = set()
            for match in result.matches:
                # Create a signature based on team names (sorted to handle order differences)
                teams = sorted([match.team1 or "", match.team2 or ""])
                signature = f"{teams[0]}|{teams[1]}"
                
                if signature not in seen_signatures:
                    seen_signatures.add(signature)
                    unique_matches.append(match)
                else:
                    logger.debug(f"  Removing duplicate: {match.team1} vs {match.team2}")
            
            result.matches = unique_matches
            # Note: total_matches is a computed property, no need to set it
            result.status = "success"
            logger.info(f"Pool scan complete: {len(result.matches)} matches extracted (after dedup)")
            
        except Exception as e:
            result.status = "error"
            result.error = str(e)
            logger.error(f"Pool scan failed: {e}")
        
        return result
    
    async def _requires_login(self) -> bool:
        """Check if the page requires login"""
        try:
            selectors = [
                'button:has-text("Sign In")',
                'text="Please sign in"'
            ]
            for selector in selectors:
                if await self.page.is_visible(selector, timeout=2000):
                    return True
            return False
        except PlaywrightTimeout:
            return False
    
    async def _find_match_containers(self) -> List:
        """Find all match card containers on the pool page"""
        logger.info("Finding match containers...")
        
        # VBL V3 uses Vuetify components - match cards are v-card elements
        # The pool page shows all matches directly visible as cards
        selectors = [
            # Primary: Vuetify card components containing match data
            'div.v-card:has(.teams-table)',          # Card with teams table inside
            'div.v-card:has(td.clickable)',          # Card with clickable team names
            'div.v-sheet:has(.teams-table)',         # Sheet variant
            # Fallback: Look for cards with match-like content
            'div.v-card',                             # Any Vuetify card
        ]
        
        containers = []
        
        for selector in selectors:
            try:
                elements = await self.page.locator(selector).all()
                logger.info(f"  Trying '{selector}': found {len(elements)} elements")
                
                if elements:
                    for el in elements:
                        try:
                            if not await el.is_visible():
                                continue
                            
                            # Check if it looks like a match card (has match number or team names)
                            text = await el.text_content() or ""
                            has_match_marker = bool(re.search(r'Match\s*\d+', text, re.I))
                            has_team_names = bool(re.search(r'[A-Z][a-z]+\s+[A-Z][a-z]+', text))
                            has_time = bool(re.search(r'\d{1,2}:\d{2}', text))
                            
                            if has_match_marker or (has_team_names and has_time):
                                containers.append(el)
                                logger.debug(f"    Added container with text: {text[:50]}...")
                        except Exception as e:
                            logger.debug(f"    Error checking element: {e}")
                            continue
                    
                    if containers:
                        logger.info(f"  Found {len(containers)} valid match containers")
                        break
                        
            except Exception as e:
                logger.debug(f"  Selector '{selector}' error: {e}")
                continue
        
        # Deduplicate by position (avoid nested duplicates)
        unique_containers = []
        positions = set()
        for el in containers:
            try:
                box = await el.bounding_box()
                if box:
                    # Round to avoid float precision issues
                    pos_key = (int(box['x'] / 10), int(box['y'] / 10))
                    if pos_key not in positions:
                        positions.add(pos_key)
                        unique_containers.append(el)
            except Exception:
                unique_containers.append(el)
        
        logger.info(f"  Returning {len(unique_containers)} unique containers")
        return unique_containers
    
    async def _process_match(self, container, index: int) -> Optional[VBLMatch]:
        """Process a single match container - extract data and API URL"""
        match = VBLMatch(index=index)
        
        try:
            # Get full text content for regex extraction
            text = await container.text_content() or ""
            logger.debug(f"  Container text: {text[:100]}...")
            
            # Extract team names from clickable cells within the card
            try:
                name_cells = await container.locator('td.clickable').all()
                if len(name_cells) >= 2:
                    match.team1 = (await name_cells[0].text_content() or "").strip()
                    match.team2 = (await name_cells[1].text_content() or "").strip()
                    logger.info(f"    Teams: {match.team1} vs {match.team2}")
            except Exception:
                # Fallback to text extraction
                team1, team2 = self._extract_teams(text)
                match.team1 = team1
                match.team2 = team2
            
            # Extract match number - VBL format: "Match 1", "Match 2", etc.
            match_num = re.search(r'Match\s*(\d+)', text, re.I)
            if match_num:
                match.match_number = match_num.group(1)
                logger.info(f"    Match #: {match.match_number}")
            
            # Extract time - VBL format: "8:00AM", "11:00AM" etc.
            # Use lookbehind to ensure time isn't preceded by another digit (avoids "219:00AM" from scores)
            # Valid times: 1:00-12:59 AM/PM
            time_match = re.search(r'(?<![0-9])((1[0-2]|[1-9]):\d{2}\s*(?:AM|PM))', text, re.I)
            if time_match:
                match.start_time = time_match.group(1).strip()
                logger.info(f"    Time: {match.start_time}")
            else:
                logger.debug(f"    No time found in text")
            
            # Extract day of week - VBL may show "Thu", "Friday", etc.
            day_patterns = [
                r'\b(Mon(?:day)?|Tue(?:sday)?|Wed(?:nesday)?|Thu(?:rsday)?|Fri(?:day)?|Sat(?:urday)?|Sun(?:day)?)\b',
                r'\b(\d{1,2}/\d{1,2}(?:/\d{2,4})?)\b',  # Date format: 12/31, 1/1/2026
            ]
            for pattern in day_patterns:
                day_match = re.search(pattern, text, re.I)
                if day_match:
                    match.start_date = day_match.group(1)
                    logger.info(f"    Date: {match.start_date}")
                    break
            
            # Extract court - VBL formats: "Court 1", "Court A", "Court Stadium", "Center Court", etc.
            # Stop at boundaries like Team, Set, Match, numbers after letters
            court_match = re.search(
                r'Court\s*(\d+|[A-Za-z]+(?:\s+Court)?)',  # "Court 1", "Court A", "Stadium Court"  
                text, 
                re.I
            )
            if court_match:
                court_val = court_match.group(1).strip()
                # Clean up: remove trailing words that aren't part of court name
                court_val = re.sub(r'(?:Team|Set|Match|Score|vs).*$', '', court_val, flags=re.I).strip()
                match.court = court_val
                logger.info(f"    Court: {match.court}")
            
            # Extract seed from avatar/badge within the card
            try:
                seed_cells = await container.locator('.v-avatar').all()
                if len(seed_cells) >= 2:
                    seed1 = (await seed_cells[0].text_content() or "").strip()
                    seed2 = (await seed_cells[1].text_content() or "").strip()
                    if seed1.isdigit():
                        match.team1_seed = seed1
                    if seed2.isdigit():
                        match.team2_seed = seed2
                    logger.debug(f"    Seeds: {seed1}, {seed2}")
            except Exception:
                pass
            
            # Try to get API URL from vMix button
            # First look for button in the container
            api_url = await self._extract_api_url_from_container(container)
            
            if not api_url:
                # Look for vMix link/button anywhere in card text (V3 shows it as text link)
                vmix_link = re.search(r'(https://api\.volleyballlife\.com[^\s"<]+vmix[^\s"<]*)', text, re.I)
                if vmix_link:
                    api_url = vmix_link.group(1)
                    logger.info(f"    API URL (from text): {api_url}")
            
            if not api_url:
                # Click the vMix button/text in the container
                try:
                    vmix_element = container.locator('text=VMix, text=vMix, text=VMIX').first
                    if await vmix_element.is_visible(timeout=1000):
                        await vmix_element.click(force=True)
                        await asyncio.sleep(1.0)
                        
                        # Look for URL in page content after click
                        content = await self.page.content()
                        api_patterns = [
                            r'(https://api\.volleyballlife\.com/api/v1\.0/matches/\d+/vmix\?bracket=true)',
                            r'(https://api\.volleyballlife\.com/api/v1\.0/matches/\d+/vmix[^"\s<]*)',
                        ]
                        for pattern in api_patterns:
                            matches = re.findall(pattern, content, re.I)
                            if matches:
                                api_url = matches[0].split()[0].split('<')[0].strip()
                                logger.info(f"    API URL (after click): {api_url}")
                                break
                except Exception as e:
                    logger.debug(f"    vMix click failed: {e}")
            
            if api_url:
                match.api_url = api_url
                
        except Exception as e:
            logger.debug(f"Error processing match container: {e}")
        
        return match
    
    async def _extract_api_url_from_container(self, container) -> Optional[str]:
        """Try to extract API URL directly from a match card container"""
        try:
            # Look for vMix button within this container
            vmix_btn = container.locator('button:has-text("VMIX"), button:has-text("vMix")').first
            
            if await vmix_btn.is_visible():
                await vmix_btn.click(force=True)
                await asyncio.sleep(1.0)
                
                # Look for API URL in page content
                content = await self.page.content()
                api_patterns = [
                    r'(https://api\.volleyballlife\.com/api/v1\.0/matches/\d+/vmix\?bracket=true)',
                    r'(https://api\.volleyballlife\.com/api/v1\.0/matches/\d+/vmix[^"\s<]+)',
                ]
                
                for pattern in api_patterns:
                    matches = re.findall(pattern, content, re.I)
                    if matches:
                        url = matches[0].split()[0].split('<')[0].strip()
                        logger.debug(f"    Found API URL: {url}")
                        return url
            
            return None
            
        except Exception as e:
            logger.debug(f"Error extracting API from container: {e}")
            return None
    
    def _extract_teams(self, text: str) -> tuple:
        """Extract team names from text"""
        team1, team2 = None, None
        
        # Pattern: "FirstName LastName / FirstName LastName"
        team_pattern = r'([A-Z][a-z]+\s+[A-Z][a-z]+(?:\s*/\s*[A-Z][a-z]+\s+[A-Z][a-z]+)?)'
        
        # Look for "vs" pattern
        vs_pattern = r'([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?(?:\s*/\s*[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)?)\s+(?:vs\.?|v\.)\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?(?:\s*/\s*[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)?)'
        m = re.search(vs_pattern, text)
        if m:
            team1 = self.clean_team_name(m.group(1))
            team2 = self.clean_team_name(m.group(2))
            return team1, team2
        
        # Look for two team-like lines
        lines = [l.strip() for l in text.split('\n') if l.strip()]
        name_lines = []
        for line in lines:
            if re.match(r'^[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?(?:\s*/\s*[A-Z][a-z]+)?', line):
                # Skip if it's just a time or match number
                if not re.match(r'^\d', line) and 'Match' not in line:
                    name_lines.append(line)
        
        if len(name_lines) >= 2:
            team1 = self.clean_team_name(name_lines[0])
            team2 = self.clean_team_name(name_lines[1])
        
        return team1, team2
    
    async def _wait_for_overlay(self) -> bool:
        """Wait for match overlay to appear"""
        overlay_selectors = [
            'div.v-overlay__content',
            'div.v-dialog',
            'div.match-card-overlay',
            'div[class*="modal"]'
        ]
        
        for selector in overlay_selectors:
            try:
                await self.page.wait_for_selector(selector, timeout=3000)
                return True
            except PlaywrightTimeout:
                continue
        
        return False
    
    async def _extract_overlay_data(self, match: VBLMatch) -> None:
        """Extract additional data from the match overlay"""
        try:
            overlay = self.page.locator('div.v-overlay__content').first
            if not await overlay.is_visible():
                overlay = self.page.locator('div.v-dialog').first
            
            if not await overlay.is_visible():
                return
            
            # Extract team names if not found
            if not match.team1:
                name_cells = await overlay.locator('td.clickable').all()
                if len(name_cells) >= 2:
                    match.team1 = (await name_cells[0].text_content() or "").strip()
                    match.team2 = (await name_cells[1].text_content() or "").strip()
            
            # Extract seeds
            seed_cells = await overlay.locator('td.d-flex.align-center.justify-center').all()
            if len(seed_cells) >= 2:
                seed1 = (await seed_cells[0].text_content() or "").strip()
                seed2 = (await seed_cells[1].text_content() or "").strip()
                if seed1.isdigit():
                    match.team1_seed = seed1
                if seed2.isdigit():
                    match.team2_seed = seed2
                    
        except Exception as e:
            logger.debug(f"Error extracting overlay data: {e}")
    
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
            await asyncio.sleep(1.0)
            
            # Look for API URL in page content
            content = await self.page.content()
            api_patterns = [
                r'(https://api\.volleyballlife\.com/api/v1\.0/matches/\d+/vmix\?bracket=true)',
                r'(https://api\.volleyballlife\.com/api/v1\.0/matches/\d+/vmix[^"\s<]+)',
            ]
            
            for pattern in api_patterns:
                matches = re.findall(pattern, content, re.I)
                if matches:
                    url = matches[0].split()[0].split('<')[0].strip()
                    return url
            
            # Look for links
            links = await self.page.locator('a[href*="api.volleyballlife.com"]').all()
            for link in links:
                if await link.is_visible():
                    href = await link.get_attribute('href')
                    if href and 'vmix' in href:
                        return href
            
            return None
            
        except Exception as e:
            logger.debug(f"Error extracting API URL: {e}")
            return None
    
    async def _close_overlay(self):
        """Close any open overlay"""
        try:
            # Try clicking scrim/backdrop
            try:
                scrim = self.page.locator('.v-overlay__scrim').first
                if await scrim.is_visible():
                    box = await scrim.bounding_box()
                    if box:
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
