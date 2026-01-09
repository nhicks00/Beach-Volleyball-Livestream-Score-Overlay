#!/usr/bin/env python3
"""
Teams Tab Scraper Module
Extracts team seed rankings from the Teams tab of a VBL division

Part of MultiCourtScore v2
"""

import asyncio
import re
from typing import Dict, Optional

from playwright.async_api import TimeoutError as PlaywrightTimeout

from .core import (
    VBLScraperBase,
    ScraperConfig,
    logger
)


class TeamsScraper(VBLScraperBase):
    """
    Scraper for VolleyballLife Teams tab.
    Extracts team name -> seed mapping for a division.
    """
    
    async def scan(
        self, 
        url: str, 
        username: str = None, 
        password: str = None
    ) -> Dict[str, str]:
        """
        Scan a Teams URL and extract team seeds.
        
        Args:
            url: The teams tab URL (e.g., /event/X/division/Y/teams)
            username: VBL username
            password: VBL password
            
        Returns:
            Dictionary mapping team display name -> seed number
        """
        seeds = {}
        
        try:
            logger.info(f"Scanning Teams tab: {url}")
            await self.page.goto(url, wait_until='networkidle')
            
            # Check login
            if await self._requires_login():
                if username and password:
                    logger.info("Login required, attempting authentication...")
                    if await self.login(username, password):
                        await self.page.goto(url, wait_until='networkidle')
                    else:
                        logger.error("Login failed")
                        return seeds
            
            # Wait for content
            await asyncio.sleep(3.0)
            
            # Extract seeds from Teams table
            seeds = await self._extract_seeds()
            
            logger.info(f"Extracted {len(seeds)} team seeds")
            
        except Exception as e:
            logger.error(f"Teams scan failed: {e}")
        
        return seeds
    
    async def _requires_login(self) -> bool:
        """Check if login is needed"""
        try:
            return await self.page.is_visible('button:has-text("Sign In")', timeout=2000)
        except PlaywrightTimeout:
            return False
    
    async def _extract_seeds(self) -> Dict[str, str]:
        """Extract team seeds from the Teams table"""
        seeds = {}
        
        # Common selectors for VBL Teams table
        table_selectors = [
            'table.v-data-table',
            'div.v-data-table',
            'table[class*="team"]',
        ]
        
        for selector in table_selectors:
            try:
                table = self.page.locator(selector).first
                if not await table.is_visible():
                    continue
                
                # Find all rows
                rows = await table.locator('tr').all()
                logger.info(f"Found {len(rows)} table rows")
                
                for row in rows:
                    try:
                        # Get all cells
                        cells = await row.locator('td').all()
                        if len(cells) < 2:
                            continue
                        
                        # First column is usually seed/rank
                        seed_text = (await cells[0].text_content() or "").strip()
                        
                        # Second column is usually team name
                        name_text = (await cells[1].text_content() or "").strip()
                        
                        # Validate seed (should be a number)
                        if seed_text.isdigit() and name_text:
                            # Clean team name (remove rankings, records, etc.)
                            clean_name = self._normalize_team_name(name_text)
                            if clean_name:
                                seeds[clean_name] = seed_text
                                logger.debug(f"  Seed {seed_text}: {clean_name}")
                                
                    except Exception as e:
                        logger.debug(f"Row extraction error: {e}")
                        continue
                
                if seeds:
                    break
                    
            except Exception as e:
                logger.debug(f"Table selector '{selector}' failed: {e}")
                continue
        
        # Fallback: Try to extract from page text
        if not seeds:
            seeds = await self._extract_seeds_from_text()
        
        return seeds
    
    async def _extract_seeds_from_text(self) -> Dict[str, str]:
        """Fallback extraction from page text"""
        seeds = {}
        
        try:
            body_text = await self.page.inner_text('body')
            
            # Pattern: "1. FirstName LastName / FirstName LastName" or similar
            pattern = r'(\d{1,2})\.\s*([A-Z][a-z]+\s+[A-Z][a-z]+(?:\s*/\s*[A-Z][a-z]+\s+[A-Z][a-z]+)?)'
            
            for match in re.finditer(pattern, body_text):
                seed = match.group(1)
                name = self._normalize_team_name(match.group(2))
                if name:
                    seeds[name] = seed
                    
        except Exception as e:
            logger.debug(f"Text extraction failed: {e}")
        
        return seeds
    
    def _normalize_team_name(self, name: str) -> str:
        """Normalize team name for matching"""
        # Remove extra whitespace
        name = ' '.join(name.split())
        # Remove common suffixes like (1-2), rankings, etc.
        name = re.sub(r'\s*\([^)]*\)\s*', ' ', name)
        name = re.sub(r'\s*\[\d+\]\s*', '', name)
        return name.strip()


def derive_teams_url(pool_url: str) -> Optional[str]:
    """
    Derive the Teams tab URL from a pool URL.
    
    e.g., /event/27644/division/104314/round/228002/pools/277767
       -> /event/27644/division/104314/teams
    """
    # Pattern to extract event and division IDs
    pattern = r'(https?://[^/]+)?/event/(\d+)/division/(\d+)'
    match = re.search(pattern, pool_url)
    
    if match:
        base = match.group(1) or 'https://volleyballlife.com'
        event_id = match.group(2)
        division_id = match.group(3)
        return f"{base}/event/{event_id}/division/{division_id}/teams"
    
    return None
