#!/usr/bin/env python3
"""
Pool Scraper Module
Pool play scanning for VolleyballLife pool pages

Part of MultiCourtScore v2 - Consolidated scraper architecture
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
            
            # Extract matches using multiple strategies
            matches = await self._extract_pool_matches()
            
            if not matches:
                # Try alternative extraction
                matches = await self._extract_matches_alternative()
            
            result.matches = matches
            result.total_matches = len(matches)
            result.status = "success"
            
            logger.info(f"Found {len(matches)} pool matches")
            
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
            lines = [l.strip() for l in text.split('\n') if l.strip()]
        except Exception:
            return None
        
        # Extract team names
        team1, team2 = self._extract_teams(text)
        match.team1 = team1
        match.team2 = team2
        
        # Extract time
        time_match = re.search(r'(\d{1,2}:\d{2}\s*(?:AM|PM)?)', text, re.I)
        if time_match:
            match.start_time = self.parse_time(time_match.group(1))
        
        # Extract court
        court_match = re.search(r'Court\s*(\d+|[A-Z])', text, re.I)
        if court_match:
            match.court = court_match.group(1)
        
        # Try to find API URL on the container
        try:
            # Look for vMix button or API link
            vmix_button = container.locator('button:has-text("VMIX"), a:has-text("VMIX")').first
            if await vmix_button.is_visible():
                await vmix_button.click()
                await asyncio.sleep(0.5)
                
                # Look for API link
                api_link = self.page.locator('a[href*="api"]').first
                if await api_link.is_visible():
                    match.api_url = await api_link.get_attribute('href')
                
                # Close any overlay
                await self.page.keyboard.press('Escape')
        except Exception:
            pass
        
        # Also check for direct link on container
        try:
            api_link = container.locator('a[href*="api"]').first
            if await api_link.is_visible():
                match.api_url = await api_link.get_attribute('href')
        except Exception:
            pass
        
        return match
    
    def _extract_teams(self, text: str) -> tuple:
        """Extract team names from text"""
        team1, team2 = None, None
        
        patterns = [
            # Name / Name format
            r'([A-Za-z]+(?:\s+[A-Za-z]+)?)\s*/\s*([A-Za-z]+(?:\s+[A-Za-z]+)?)',
            # Name vs Name format
            r'([A-Za-z]+(?:\s+[A-Za-z]+)?)\s+vs\.?\s+([A-Za-z]+(?:\s+[A-Za-z]+)?)',
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
            lines = [l.strip() for l in text.split('\n') if l.strip()]
            name_lines = [l for l in lines if re.match(r'^[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?(?:\s*/\s*[A-Z][a-z]+)?$', l)]
            if len(name_lines) >= 2:
                team1 = self.clean_team_name(name_lines[0])
                team2 = self.clean_team_name(name_lines[1])
        
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
