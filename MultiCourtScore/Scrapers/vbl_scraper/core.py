#!/usr/bin/env python3
"""
VBL Scraper Core - Consolidated base classes and utilities
VolleyballLife bracket/pool scraping with proper login handling

Part of MultiCourtScore v2 - Complete rewrite based on v1 proven patterns
"""

import asyncio
import json
import logging
import os
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import List, Optional, Dict, Any

from playwright.async_api import async_playwright, Browser, Page, BrowserContext

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(name)s: %(message)s',
    datefmt='%H:%M:%S'
)
logger = logging.getLogger('vbl_scraper')


@dataclass
class ScraperConfig:
    """Configuration for the VBL scraper"""
    headless: bool = True
    timeout: int = 30000
    session_file: Optional[Path] = None
    results_file: Optional[Path] = None
    slow_mo: int = 0  # Milliseconds to slow down operations
    
    def __post_init__(self):
        if self.session_file is None:
            self.session_file = Path.home() / '.multicourtscore' / 'session.json'


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
    api_url: Optional[str] = None
    match_type: Optional[str] = None
    type_detail: Optional[str] = None
    
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
            'api_url': self.api_url,
            'match_type': self.match_type,
            'type_detail': self.type_detail
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


class VBLScraperBase:
    """
    Base class for VBL scrapers with proven 4-phase login from v1
    """
    
    def __init__(self, config: Optional[ScraperConfig] = None):
        self.config = config or ScraperConfig()
        self.playwright = None
        self.browser: Optional[Browser] = None
        self.context: Optional[BrowserContext] = None
        self.page: Optional[Page] = None
        self._captured_api_urls: List[str] = []
    
    async def __aenter__(self):
        await self.start()
        return self
    
    async def __aexit__(self, exc_type, exc_val, exc_tb):
        await self.close()
    
    async def start(self):
        """Initialize browser"""
        logger.info("Starting browser...")
        self.playwright = await async_playwright().start()
        
        self.browser = await self.playwright.chromium.launch(
            headless=self.config.headless,
            slow_mo=self.config.slow_mo
        )
        
        self.context = await self.browser.new_context(
            viewport={'width': 1400, 'height': 900},
            user_agent='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36'
        )
        
        self.page = await self.context.new_page()
        self.page.set_default_timeout(self.config.timeout)
        
        # Set up network request interception for API URL capture
        self.page.on('request', self._capture_api_requests)
        
        logger.info("Browser started successfully")
    
    async def close(self):
        """Clean up browser"""
        if self.browser:
            await self.browser.close()
        if self.playwright:
            await self.playwright.stop()
        logger.info("Browser closed")
    
    def _capture_api_requests(self, request):
        """Capture API URLs from network requests"""
        url = request.url
        if 'api.volleyballlife.com' in url and '/vmix' in url:
            if url not in self._captured_api_urls:
                self._captured_api_urls.append(url)
                logger.debug(f"Captured API URL: {url}")
    
    # ==================== 4-PHASE LOGIN (from v1) ====================
    
    async def check_login_status(self) -> bool:
        """Check if already logged in by looking for profile indicators"""
        try:
            # Look for user profile indicators
            profile_selectors = [
                '[class*="avatar"]',
                'button:has-text("Logout")',
                'a:has-text("Profile")'
            ]
            
            for selector in profile_selectors:
                try:
                    if await self.page.is_visible(selector):
                        logger.info(f"Found logged-in indicator: {selector}")
                        return True
                except Exception:
                    continue
            
            # Look for Sign In button - means not logged in
            if await self.page.is_visible('button:has-text("Sign In")'):
                return False
                
            return False
            
        except Exception as e:
            logger.warning(f"Error checking login status: {e}")
            return False
    
    async def phase_1_initial_setup(self):
        """
        Phase 1: Navigate to VBL and check for V3 view switch
        """
        logger.info("PHASE 1: Initial setup and V3 view check")
        
        await self.page.goto('https://volleyballlife.com')
        await self.page.wait_for_load_state('networkidle')
        
        # Check for V3 switch button
        try:
            v3_selector = 'button:has-text("SWITCH TO V3 VIEW")'
            if await self.page.is_visible(v3_selector):
                logger.info("Found V3 switch button - clicking...")
                await self.page.click(v3_selector)
                await self.page.wait_for_load_state('networkidle')
                await asyncio.sleep(1.2)
                logger.info("Switched to V3 view")
            else:
                logger.info("Already in V3 view")
        except Exception as e:
            logger.warning(f"V3 switch check: {e}")
    
    async def phase_2_open_signin_modal(self) -> bool:
        """
        Phase 2: Click Sign In button to open modal
        """
        logger.info("PHASE 2: Opening sign-in modal")
        
        try:
            sign_in_selector = 'button:has-text("Sign In")'
            await self.page.wait_for_selector(sign_in_selector, timeout=10000)
            await self.page.click(sign_in_selector)
            logger.info("Clicked Sign In button")
            
            # Wait for modal
            modal_selector = 'div.v-card-title:has-text("Sign In or Sign Up")'
            await self.page.wait_for_selector(modal_selector, timeout=10000)
            logger.info("Sign-in modal opened")
            
            return True
            
        except Exception as e:
            logger.error(f"Phase 2 failed: {e}")
            return False
    
    async def phase_3_enter_credentials(self, username: str, password: str) -> bool:
        """
        Phase 3: Enter email -> Continue -> password -> Sign In
        
        VBL modal has both "Sign In" and "Create Account" sections.
        We need to find the email field in the sign-in section specifically.
        """
        logger.info("PHASE 3: Entering credentials")
        
        try:
            # Wait for modal to fully load
            await asyncio.sleep(1.0)
            
            # Step 1: Find the email field in the SIGN IN section
            # The modal structure typically has the sign-in section first
            logger.info("Step 1: Looking for sign-in email field...")
            
            # Try to find the email input - typically the first text input in the modal
            # that's not in a "create account" section
            email_field = None
            
            # Strategy 1: Look for input near "Sign In" text
            try:
                # Find all text inputs in the modal card
                all_inputs = await self.page.locator('div.v-card input[type="text"]').all()
                
                for input_elem in all_inputs:
                    if await input_elem.is_visible() and await input_elem.is_enabled():
                        # Get placeholder to verify it's an email field
                        placeholder = await input_elem.get_attribute('placeholder') or ""
                        aria_label = await input_elem.get_attribute('aria-label') or ""
                        
                        # Skip search boxes
                        if 'search' in placeholder.lower() or 'search' in aria_label.lower():
                            continue
                        
                        # Check if this input is likely the sign-in email field
                        # It should be the first visible email-type input
                        email_field = input_elem
                        logger.info(f"Found email field (placeholder: {placeholder})")
                        break
                        
            except Exception as e:
                logger.warning(f"Strategy 1 failed: {e}")
            
            # Strategy 2: Use more specific selectors
            if not email_field:
                email_selectors = [
                    'input[aria-label*="email" i]',
                    'input[placeholder*="email" i]',
                    'div.v-field input[type="text"]'
                ]
                
                for selector in email_selectors:
                    try:
                        elements = await self.page.locator(selector).all()
                        for elem in elements:
                            if await elem.is_visible() and await elem.is_enabled():
                                email_field = elem
                                logger.info(f"Found email field with: {selector}")
                                break
                        if email_field:
                            break
                    except Exception:
                        continue
            
            if not email_field:
                logger.error("Could not find email input field")
                return False
            
            # Enter the email
            await email_field.click()  # Focus the field first
            await asyncio.sleep(0.3)
            await email_field.fill(username)
            logger.info(f"Entered email: {username}")
            
            # Step 2: Click Continue button
            logger.info("Step 2: Clicking Continue...")
            await asyncio.sleep(0.5)
            
            # Find and click Continue button
            continue_btn = self.page.locator('button:has-text("Continue")').first
            await continue_btn.click()
            logger.info("Clicked Continue")
            
            # Step 3: Wait for password field to appear
            logger.info("Step 3: Waiting for password field...")
            password_selector = 'input[type="password"]'
            await self.page.wait_for_selector(password_selector, timeout=15000)
            logger.info("Password field appeared")
            
            # Step 4: Enter password
            logger.info("Step 4: Entering password...")
            await asyncio.sleep(0.3)
            await self.page.fill(password_selector, password)
            logger.info("Password entered")
            
            # Small delay to let form process
            await asyncio.sleep(0.8)
            
            # Step 5: Click final Sign In button
            logger.info("Step 5: Clicking final Sign In...")
            
            # The Sign In button should be visible now
            final_signin_selectors = [
                'div.v-card button:has-text("Sign In")',
                'button.v-btn:has-text("Sign In")',
                'button:has-text("Sign In"):visible'
            ]
            
            for selector in final_signin_selectors:
                try:
                    buttons = await self.page.locator(selector).all()
                    for btn in buttons:
                        if await btn.is_visible() and await btn.is_enabled():
                            await btn.click()
                            logger.info(f"Clicked Sign In button")
                            return True
                except Exception:
                    continue
            
            # Fallback: press Enter
            logger.info("Using Enter key as fallback...")
            await self.page.keyboard.press('Enter')
            return True
            
        except Exception as e:
            logger.error(f"Phase 3 failed: {e}")
            return False
    
    async def phase_4_confirm_login(self) -> bool:
        """
        Phase 4: Wait for Sign In button to disappear
        """
        logger.info("PHASE 4: Confirming login")
        
        try:
            # Wait for Sign In button to disappear
            await self.page.wait_for_selector(
                'button:has-text("Sign In")',
                state='hidden',
                timeout=15000
            )
            logger.info("Login confirmed - Sign In button disappeared")
            
            await asyncio.sleep(1.2)
            return True
            
        except Exception as e:
            logger.warning(f"Phase 4 timeout: {e}")
            
            # Try alternative confirmation
            profile_selectors = [
                '[class*="profile"]',
                '[class*="avatar"]',
                'button:has-text("Logout")'
            ]
            
            for selector in profile_selectors:
                try:
                    if await self.page.is_visible(selector):
                        logger.info(f"Found profile indicator: {selector}")
                        return True
                except Exception:
                    continue
            
            return False
    
    async def login(self, username: str, password: str) -> bool:
        """
        Complete 4-phase login process
        """
        logger.info("Starting 4-phase login process...")
        
        # Phase 1
        await self.phase_1_initial_setup()
        
        # Check if already logged in
        if await self.check_login_status():
            logger.info("Already logged in!")
            return True
        
        # Phase 2
        if not await self.phase_2_open_signin_modal():
            return False
        
        # Phase 3
        if not await self.phase_3_enter_credentials(username, password):
            return False
        
        # Phase 4
        if not await self.phase_4_confirm_login():
            return False
        
        logger.info("Login completed successfully!")
        return True
    
    # ==================== URL TYPE DETECTION ====================
    
    def determine_url_type(self, url: str) -> tuple:
        """Determine match type from URL"""
        url_lower = url.lower()
        
        if '/pools/' in url_lower:
            import re
            pool_match = re.search(r'/pools/(\d+)', url_lower)
            pool_num = pool_match.group(1) if pool_match else "Unknown"
            return "Pool Play", f"Pool {pool_num}"
        elif '/brackets/' in url_lower:
            if 'contenders' in url_lower:
                return "Bracket Play", "Contenders Bracket"
            elif 'winners' in url_lower:
                return "Bracket Play", "Winners Bracket"
            else:
                return "Bracket Play", "Main Bracket"
        else:
            return "Bracket Play", "Main Bracket"
    
    # ==================== SCANNING ====================
    
    async def scan(self, url: str, username: str = None, password: str = None) -> ScanResult:
        """
        Scan a VBL URL for matches - to be implemented by subclasses
        """
        raise NotImplementedError("Subclasses must implement scan()")
