#!/usr/bin/env python3
"""
Pool Scraper Module
Pool play scanning for VolleyballLife pool pages

Part of MultiCourtScore v2 - Consolidated scraper architecture
"""

import asyncio
import re
from typing import List, Optional, Tuple

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
    Pool pages typically show matches more openly without requiring clicks.
    """
    
    async def scan(
        self, 
        url: str, 
        username: str = None, 
        password: str = None
    ) -> ScanResult:
        """
        Scan a pool URL and extract all match data.
        
        Args:
            url: The pool URL to scan
            username: VBL username (for login if needed)
            password: VBL password (for login if needed)
            
        Returns:
            ScanResult with extracted match data
        """
        result = ScanResult(url=url)
        match_type, type_detail = self.determine_url_type(url)
        result.match_type = match_type
        result.type_detail = type_detail
        
        try:
            logger.info(f"Scanning pool: {url}")
            await self.page.goto(url, wait_until='networkidle')
            
            # Check for login required
            if await self._requires_login():
                if username and password:
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
            
            # Wait for pool content
            await self._wait_for_pool_content()

            # Extract pool-specific match format (often differs from bracket rules).
            match_format = await self._extract_pool_match_format()
            logger.info(f"Pool format: {match_format.get('format_text', 'Not found')}")
            
            # Extract matches using multiple strategies
            matches = await self._extract_pool_matches()
            
            if not matches:
                # Try alternative extraction
                matches = await self._extract_matches_alternative()

            # Apply the discovered format to every match from this pool URL.
            for match in matches:
                match.sets_to_win = match_format['sets_to_win']
                match.points_per_set = match_format['points_per_set']
                match.point_cap = match_format['point_cap']
                match.format_text = match_format['format_text']
            
            result.matches = matches
            result.status = "success"
            
            logger.info(f"Found {len(matches)} pool matches")
            
        except Exception as e:
            result.status = "error"
            result.error = str(e)
            logger.error(f"Pool scan failed: {e}")
        
        return result

    async def _extract_pool_match_format(self) -> dict:
        """
        Extract and parse match format for pool pages.
        Falls back to scanning body text when the standard v-alert selector isn't present.
        """
        from .parse_format import parse_format_text

        # First try the shared extractor used by bracket pages.
        parsed = await self.extract_match_format()
        if parsed.get('format_text'):
            return parsed

        # Fallback for pool layouts where the format text is not in v-alert__content.
        try:
            body_text = await self.page.inner_text('body')
        except Exception:
            return parsed

        for raw_line in body_text.split('\n'):
            line = self._normalize_line(raw_line)
            if not line:
                continue

            lower = line.lower()

            # Narrow candidates to lines that likely describe tournament format.
            has_header_hint = re.search(r'\ball\s+matches?\b', lower) is not None
            has_format_hint = any(token in lower for token in [
                "match play",
                "best",
                "game to",
                "set to",
                "cap at",
                "no cap",
                "win by 2",
            ])
            if not (has_header_hint and has_format_hint):
                continue

            format_values = parse_format_text(line)
            format_values['format_text'] = line
            logger.info(f"Parsed pool format from body text: {format_values}")
            return format_values

        return parsed
    
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
    
    async def _wait_for_pool_content(self) -> None:
        """Wait for pool content to load"""
        pool_selectors = [
            'div[class*="pool"]',
            'div.match-row',
            'div[class*="match-card"]',
            'table[class*="pool"]'
        ]
        
        for selector in pool_selectors:
            try:
                await self.page.wait_for_selector(selector, timeout=5000)
                return
            except PlaywrightTimeout:
                continue
        
        await asyncio.sleep(2)
    
    async def _extract_pool_matches(self) -> List[VBLMatch]:
        """Extract matches from pool page"""
        matches = []
        
        # Pool match container selectors
        container_selectors = [
            'div.match-row',
            'div[class*="pool-match"]',
            'div[class*="match-card"]',
            'tr[class*="match"]'
        ]
        
        for selector in container_selectors:
            try:
                elements = await self.page.locator(selector).all()
                if not elements:
                    continue
                
                for i, el in enumerate(elements):
                    try:
                        if not await el.is_visible():
                            continue
                        
                        match = await self._extract_match_from_container(el, i)
                        if match and (match.team1 or match.api_url):
                            matches.append(match)
                    except Exception as e:
                        logger.debug(f"Error extracting match {i}: {e}")
                        continue
                
                if matches:
                    break
                    
            except Exception:
                continue
        
        return matches
    
    async def _extract_match_from_container(self, container, index: int) -> Optional[VBLMatch]:
        """Extract match data from a container element"""
        match = VBLMatch(index=index)
        
        try:
            text = await container.inner_text()
            lines = [self._normalize_line(l) for l in text.split('\n')]
            lines = [l for l in lines if l]
        except Exception:
            return None
        
        # Match number (e.g. "Match 7")
        match_num = re.search(r'\bMatch\s*(\d+)\b', text, re.I)
        if match_num:
            match.match_number = match_num.group(1)
        
        # Extract team names
        team1, team2, team1_seed, team2_seed = self._extract_teams_from_lines(lines)
        if not team1 or not team2:
            fallback_team1, fallback_team2 = self._extract_teams(text)
            team1 = team1 or fallback_team1
            team2 = team2 or fallback_team2

        match.team1 = team1
        match.team2 = team2
        match.team1_seed = team1_seed
        match.team2_seed = team2_seed
        
        # Extract time
        time_match = re.search(r'(\d{1,2}:\d{2}\s*(?:AM|PM)?)', text, re.I)
        if time_match:
            match.start_time = self.parse_time(time_match.group(1))
        
        # Extract court
        court_match = re.search(r'(?:Court|Ct)\s*([A-Z0-9]+)', text, re.I)
        if court_match:
            match.court = court_match.group(1)
        
        # Try to find API URL on the container
        try:
            # Look for vMix button or API link
            vmix_button = container.locator('button:has-text("VMIX"), a:has-text("VMIX")').first
            if await vmix_button.is_visible():
                captured_before = set(self._captured_api_urls)
                await vmix_button.click(force=True)
                await asyncio.sleep(1.2)

                # Prefer newly captured network request URLs for this specific click
                new_urls = [u for u in self._captured_api_urls if u not in captured_before]
                if new_urls:
                    match.api_url = new_urls[-1]

                # Fallback: parse rendered dialog/page content
                if not match.api_url:
                    match.api_url = await self._extract_api_url_from_content()

                # Close any overlay
                await self.page.keyboard.press('Escape')
                await asyncio.sleep(0.15)
        except Exception:
            pass
        
        # Also check for direct link on container
        if not match.api_url:
            try:
                api_link = container.locator('a[href*="api"]').first
                if await api_link.is_visible():
                    match.api_url = await api_link.get_attribute('href')
            except Exception:
                pass
        
        return match

    def _normalize_line(self, line: str) -> str:
        """Normalize whitespace and strip control characters from text lines."""
        return re.sub(r'\s+', ' ', line).strip()

    def parse_time(self, raw_time: str) -> Optional[str]:
        """Normalize time string to VBL app format, e.g. '9:00 AM' -> '9:00AM'."""
        if not raw_time:
            return None

        cleaned = re.sub(r'\s+', '', raw_time).upper()
        m = re.search(r'(\d{1,2}:\d{2})(AM|PM)?', cleaned)
        if not m:
            return raw_time.strip()

        hhmm = m.group(1)
        ampm = m.group(2) or ""
        return f"{hhmm}{ampm}"

    def clean_team_name(self, raw_name: str) -> Optional[str]:
        """Clean team/player text while preserving real names."""
        if not raw_name:
            return None

        name = self._normalize_line(raw_name)
        name = re.sub(r'^[#\s]*\d+\s+', '', name)  # Remove leading seeds
        name = re.sub(r'\s+\d+$', '', name)        # Remove trailing scores
        name = name.strip(' -|:')

        if not name or not re.search(r'[A-Za-z]', name):
            return None
        if re.search(r'\b(match|court|team|ref|vmix|set)\b', name, re.I):
            return None

        return name

    def _looks_like_name(self, line: str) -> bool:
        """Heuristic check for a line that likely contains a player/team name."""
        if not line:
            return False
        if re.fullmatch(r'\d+', line):
            return False
        return self.clean_team_name(line) is not None

    def _extract_teams_from_lines(
        self,
        lines: List[str]
    ) -> Tuple[Optional[str], Optional[str], Optional[str], Optional[str]]:
        """
        Extract teams from VBL pool card lines.

        Current VBL pool cards are typically:
          seed -> player 1 -> player 2 -> score
          seed -> player 1 -> player 2 -> score
        """
        teams: List[Tuple[str, str]] = []
        i = 0

        while i < len(lines):
            line = lines[i]

            # Team rows start with a numeric seed followed by a player name line
            if not re.fullmatch(r'\d{1,3}', line):
                i += 1
                continue

            next_line = lines[i + 1] if i + 1 < len(lines) else ""
            if not self._looks_like_name(next_line):
                i += 1
                continue

            seed = line
            players: List[str] = []
            j = i + 1

            while j < len(lines):
                candidate = lines[j]
                lowered = candidate.lower()

                if lowered.startswith('ref') or lowered == 'vmix':
                    break

                if re.fullmatch(r'\d{1,3}', candidate):
                    # Score or next team seed once we've captured at least one player
                    if players:
                        break
                    j += 1
                    continue

                cleaned = self.clean_team_name(candidate)
                if cleaned:
                    players.append(cleaned)

                j += 1

            if players:
                # Beach teams are usually two player lines; keep a single line if only one was found
                team_name = " / ".join(players[:2]) if len(players) >= 2 else players[0]
                teams.append((seed, team_name))
                if len(teams) == 2:
                    break

            i = j

        team1_seed = teams[0][0] if len(teams) >= 1 else None
        team1 = teams[0][1] if len(teams) >= 1 else None
        team2_seed = teams[1][0] if len(teams) >= 2 else None
        team2 = teams[1][1] if len(teams) >= 2 else None

        return team1, team2, team1_seed, team2_seed

    async def _extract_api_url_from_content(self) -> Optional[str]:
        """Extract vMix API URL from the active page/dialog content."""
        try:
            content = await self.page.content()
            urls = re.findall(
                r'https://api\.volleyballlife\.com/api/v1\.0/matches/\d+/vmix[^"\s<]*',
                content,
                re.I
            )
            if urls:
                # The active dialog appends/updates URLs; newest entry is usually the current match.
                return urls[-1].replace('&amp;', '&')

            inputs = await self.page.locator('input[value*="api.volleyballlife.com"]').all()
            for inp in inputs:
                val = await inp.get_attribute('value')
                if val and 'vmix' in val:
                    return val
        except Exception:
            pass
        return None
    
    def _extract_teams(self, text: str) -> tuple:
        """Extract team names from text"""
        team1, team2 = None, None
        
        patterns = [
            # Name / Name format
            r'([A-Za-z][A-Za-z\'\-\.\(\)\s]{1,80})\s*/\s*([A-Za-z][A-Za-z\'\-\.\(\)\s]{1,80})',
            # Name vs Name format
            r'([A-Za-z][A-Za-z\'\-\.\(\)\s]{1,80})\s+vs\.?\s+([A-Za-z][A-Za-z\'\-\.\(\)\s]{1,80})',
            # Two separate lines with names
            r'^([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)\s*$',
        ]
        
        for pattern in patterns[:2]:
            m = re.search(pattern, text, re.M)
            if m:
                team1 = self.clean_team_name(m.group(1))
                team2 = self.clean_team_name(m.group(2))
                break
        
        # Fallback: try to find name-like lines
        if not team1:
            lines = [self._normalize_line(l) for l in text.split('\n') if self._normalize_line(l)]
            name_lines = [self.clean_team_name(l) for l in lines if self._looks_like_name(l)]
            name_lines = [n for n in name_lines if n]
            if len(name_lines) >= 2:
                team1 = name_lines[0]
                team2 = name_lines[1]
        
        return team1, team2
    
    async def _extract_matches_alternative(self) -> List[VBLMatch]:
        """Alternative extraction when standard selectors don't work"""
        matches = []
        
        try:
            # Get all text on page
            body_text = await self.page.inner_text('body')
            
            # Look for patterns like "Name/Name vs Name/Name"
            team_vs_pattern = r'([A-Z][a-z]+(?:\s*/\s*[A-Z][a-z]+)?)\s+vs\.?\s+([A-Z][a-z]+(?:\s*/\s*[A-Z][a-z]+)?)'
            
            for i, m in enumerate(re.finditer(team_vs_pattern, body_text)):
                match = VBLMatch(
                    index=i,
                    team1=self.clean_team_name(m.group(1)),
                    team2=self.clean_team_name(m.group(2))
                )
                matches.append(match)
            
        except Exception as e:
            logger.debug(f"Alternative extraction failed: {e}")
        
        return matches
