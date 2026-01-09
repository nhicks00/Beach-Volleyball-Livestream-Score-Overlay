#!/usr/bin/env python3
"""
VolleyballLife Bracket Scanner using Playwright
Modern replacement for Selenium-based scraping with async/await support
"""

import asyncio
import json
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from urllib.parse import urljoin, urlparse

from playwright.async_api import Browser, BrowserContext, Page, Playwright, async_playwright


class VBLPlaywrightScraper:
    def __init__(self, headless: bool = True, timeout: int = 30000):
        self.headless = headless
        self.timeout = timeout
        self.browser: Optional[Browser] = None
        self.context: Optional[BrowserContext] = None
        self.page: Optional[Page] = None
        self.session_file = Path("vbl_session.json")
        
    async def __aenter__(self):
        """Async context manager entry"""
        await self.start()
        return self
        
    async def __aexit__(self, exc_type, exc_val, exc_tb):
        """Async context manager exit"""
        await self.close()
        
    async def start(self):
        """Initialize Playwright browser and context"""
        print("🚀 Starting Playwright WebKit browser...")
        self.playwright = await async_playwright().start()
        
        # Launch WebKit browser with realistic user agent and centered positioning
        launch_args = ['--no-sandbox', '--disable-dev-shm-usage']
        
        if not self.headless:
            # Add window positioning arguments to center the browser
            # Calculate center position for 1280x720 window
            screen_width = 1920  # Assume common screen width
            screen_height = 1080  # Assume common screen height
            window_width = 1280
            window_height = 720
            x = (screen_width - window_width) // 2
            y = (screen_height - window_height) // 2
            
            launch_args.extend([
                f'--window-position={x},{y}',
                f'--window-size={window_width},{window_height}',
            ])
            print(f"📍 Setting browser window position: {x},{y} size: {window_width}x{window_height}")
        
        self.browser = await self.playwright.webkit.launch(
            headless=self.headless,
            args=launch_args
        )
        
        # Check if we have a saved session to restore
        storage_state = None
        if self.session_file.exists():
            try:
                with open(self.session_file, 'r') as f:
                    session_data = json.load(f)
                if 'storage_state' in session_data:
                    storage_state = session_data['storage_state']
                    print("🔑 Loading previous session...")
            except Exception as e:
                print(f"⚠️ Failed to load session data: {e}")
        
        # Create context with realistic settings and session
        context_options = {
            'user_agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.1 Safari/605.1.15',
            'viewport': {'width': 1280, 'height': 720}
        }
        
        if storage_state:
            context_options['storage_state'] = storage_state
            
        self.context = await self.browser.new_context(**context_options)
        
        # Create new page
        self.page = await self.context.new_page()
        self.page.set_default_timeout(self.timeout)
        
        
        print("✅ Browser initialized successfully")
        
    async def close(self):
        """Clean up browser resources"""
        if self.page:
            await self.page.close()
        if self.context:
            await self.context.close()  
        if self.browser:
            await self.browser.close()
        if self.playwright:
            await self.playwright.stop()
        print("🔒 Browser closed")
        
    async def save_session(self):
        """Save browser session (cookies, storage) to file"""
        try:
            if not self.context:
                return
                
            # Get cookies and storage state
            cookies = await self.context.cookies()
            storage_state = await self.context.storage_state()
            
            session_data = {
                'timestamp': datetime.now().isoformat(),
                'cookies': cookies,
                'storage_state': storage_state
            }
            
            with open(self.session_file, 'w') as f:
                json.dump(session_data, f, indent=2)
            print(f"💾 Session saved to {self.session_file}")
            
        except Exception as e:
            print(f"⚠️ Failed to save session: {e}")
            
    async def check_login_status(self) -> bool:
        """Check if currently logged into VolleyballLife"""
        try:
            print("🔍 Checking current login status...")
            await self.page.goto('https://volleyballlife.com')
            await self.page.wait_for_load_state('networkidle')
            
            # Look for sign-in button vs user profile indicators
            sign_in_visible = await self.page.locator('button:has-text("Sign In")').is_visible()
            
            if sign_in_visible:
                print("❌ Not logged in - Sign In button visible")
                return False
            else:
                print("✅ Already logged in - no Sign In button found")
                return True
                
        except Exception as e:
            print(f"⚠️ Error checking login status: {e}")
            return False
            
    async def login(self, username: str, password: str) -> bool:
        """
        Perform login to VolleyballLife.com
        Returns True if successful, False otherwise
        """
        try:
            print("🔐 Attempting login to VolleyballLife...")
            
            # Navigate to login page
            await self.page.goto('https://volleyballlife.com/signin')
            await self.page.wait_for_load_state('networkidle')
            
            # Check if already logged in
            if await self.is_logged_in():
                print("✅ Already logged in!")
                return True
                
            # Fill login form
            await self.page.fill('input[name="email"], input[type="email"]', username)
            await self.page.fill('input[name="password"], input[type="password"]', password)
            
            # Click login button
            login_button = self.page.locator('button:has-text("Sign In"), input[type="submit"]').first
            await login_button.click()
            
            # Wait for navigation or error
            try:
                await self.page.wait_for_url('**/dashboard', timeout=10000)
                print("✅ Login successful - redirected to dashboard")
                await self.save_session()
                return True
            except:
                # Check for error messages
                error_element = self.page.locator('.error, .alert-danger, [class*="error"]').first
                if await error_element.is_visible():
                    error_text = await error_element.text_content()
                    print(f"❌ Login failed: {error_text}")
                else:
                    print("❌ Login failed - no redirect to dashboard")
                return False
                
        except Exception as e:
            print(f"❌ Login error: {e}")
            return False
            
    async def is_logged_in(self) -> bool:
        """Check if currently logged in by looking for user-specific elements"""
        try:
            # Look for logout link or user profile indicators
            logout_indicators = [
                'a:has-text("Logout")',
                'a:has-text("Sign Out")', 
                'a:has-text("Profile")',
                '[href*="logout"]',
                '[href*="profile"]'
            ]
            
            for selector in logout_indicators:
                element = self.page.locator(selector).first
                if await element.is_visible():
                    print("✅ User is logged in")
                    return True
                    
            print("❌ User is not logged in")
            return False
            
        except Exception as e:
            print(f"⚠️ Could not determine login status: {e}")
            return False
            
    async def scan_bracket_url(self, bracket_url: str) -> Dict:
        """
        Scan a specific bracket URL and extract match data
        Returns structured match data
        """
        try:
            print(f"🔍 Scanning bracket: {bracket_url}")
            
            # Navigate to bracket page
            await self.page.goto(bracket_url)
            await self.page.wait_for_load_state('networkidle')
            
            # Extract matches from the bracket
            matches = await self.extract_matches()
            
            result = {
                'url': bracket_url,
                'timestamp': datetime.now().isoformat(),
                'match_count': len(matches),
                'matches': matches,
                'status': 'success'
            }
            
            print(f"✅ Found {len(matches)} matches in bracket")
            return result
            
        except Exception as e:
            print(f"❌ Error scanning bracket: {e}")
            return {
                'url': bracket_url,
                'timestamp': datetime.now().isoformat(),
                'error': str(e),
                'status': 'error'
            }
            
    async def extract_matches(self) -> List[Dict]:
        """Extract match information from the current bracket page"""
        matches = []
        
        try:
            # Wait for bracket content to load
            await self.page.wait_for_selector('.bracket, .match, [class*="match"]', timeout=5000)
            
            # Look for match elements using various selectors
            match_selectors = [
                '.match',
                '[class*="match"]',
                '.game',
                '[class*="game"]',
                '.team-vs-team',
                '[class*="bracket"] .row'
            ]
            
            for selector in match_selectors:
                match_elements = await self.page.locator(selector).all()
                
                if match_elements:
                    print(f"📋 Found {len(match_elements)} potential matches with selector: {selector}")
                    
                    for i, element in enumerate(match_elements):
                        try:
                            match_data = await self.extract_single_match(element, i)
                            if match_data:
                                matches.append(match_data)
                        except Exception as e:
                            print(f"⚠️ Error extracting match {i}: {e}")
                    
                    break  # Use first successful selector
            
            # If no matches found with standard selectors, try text-based extraction
            if not matches:
                matches = await self.extract_matches_by_text()
                
        except Exception as e:
            print(f"⚠️ Error in match extraction: {e}")
            
        return matches
        
    async def extract_single_match(self, element, index: int) -> Optional[Dict]:
        """Extract data from a single match element"""
        try:
            # Get all text content
            text_content = await element.text_content() or ""
            text_content = text_content.strip()
            
            if len(text_content) < 3:  # Skip empty or very short elements
                return None
                
            # Look for team names (various patterns)
            team_patterns = [
                r'(.+?)\s+vs?\s+(.+?)(?:\s|$)',
                r'(.+?)\s+-\s+(.+?)(?:\s|$)',
                r'(.+?)\s+v\s+(.+?)(?:\s|$)',
            ]
            
            team1, team2 = None, None
            for pattern in team_patterns:
                match = re.search(pattern, text_content, re.IGNORECASE)
                if match:
                    team1, team2 = match.groups()
                    team1, team2 = team1.strip(), team2.strip()
                    break
            
            # Try to find court/location info
            court_match = re.search(r'court\s*(\d+)', text_content, re.IGNORECASE)
            court = court_match.group(1) if court_match else None
            
            # Try to find time info
            time_match = re.search(r'(\d{1,2}:\d{2}(?:\s*[AaPp][Mm])?)', text_content)
            time_str = time_match.group(1) if time_match else None
            
            # Look for any data attributes or links
            match_id = await element.get_attribute('data-match-id') or await element.get_attribute('data-id')
            match_link = await element.locator('a').first.get_attribute('href') if await element.locator('a').first.is_visible() else None
            
            match_data = {
                'index': index,
                'team1': team1,
                'team2': team2,
                'court': court,
                'time': time_str,
                'match_id': match_id,
                'link': match_link,
                'raw_text': text_content
            }
            
            # Only return if we found meaningful data
            if team1 or team2 or match_id or (len(text_content) > 10 and any(word in text_content.lower() for word in ['vs', 'v ', ' - ', 'court', 'match'])):
                return match_data
                
        except Exception as e:
            print(f"⚠️ Error extracting single match: {e}")
            
        return None
        
    async def extract_matches_by_text(self) -> List[Dict]:
        """Fallback: extract matches by searching page text for patterns"""
        matches = []
        
        try:
            page_text = await self.page.text_content('body') or ""
            
            # Look for "Team A vs Team B" patterns
            vs_pattern = r'([A-Za-z\s\d]+?)\s+vs?\s+([A-Za-z\s\d]+?)(?:\s|$|<|&)'
            vs_matches = re.finditer(vs_pattern, page_text, re.IGNORECASE | re.MULTILINE)
            
            for i, match in enumerate(vs_matches):
                team1, team2 = match.groups()
                team1, team2 = team1.strip(), team2.strip()
                
                # Filter out very short or generic terms
                if len(team1) > 2 and len(team2) > 2 and not any(word in team1.lower() + team2.lower() for word in ['click', 'select', 'choose', 'all']):
                    matches.append({
                        'index': i,
                        'team1': team1,
                        'team2': team2,
                        'court': None,
                        'time': None,
                        'match_id': None,
                        'link': None,
                        'raw_text': f"{team1} vs {team2}",
                        'extraction_method': 'text_pattern'
                    })
                    
            print(f"📝 Extracted {len(matches)} matches using text patterns")
                    
        except Exception as e:
            print(f"⚠️ Error in text-based extraction: {e}")
            
        return matches
        
    async def get_api_data(self, api_url: str) -> Optional[Dict]:
        """Fetch data from VolleyballLife API endpoints"""
        try:
            print(f"🌐 Fetching API data: {api_url}")
            
            response = await self.page.request.get(api_url, headers={
                'Accept': 'application/json',
                'X-Requested-With': 'XMLHttpRequest'
            })
            
            if response.ok:
                data = await response.json()
                print(f"✅ API data retrieved successfully")
                return data
            else:
                print(f"❌ API request failed: {response.status}")
                return None
                
        except Exception as e:
            print(f"❌ API request error: {e}")
            return None


async def main():
    """Main execution function"""
    if len(sys.argv) < 2:
        print("Usage: python3 vbl_playwright_scraper.py <bracket_url> [username] [password]")
        print("Example: python3 vbl_playwright_scraper.py 'https://volleyballlife.com/event/123/brackets'")
        sys.exit(1)
        
    bracket_url = sys.argv[1]
    username = sys.argv[2] if len(sys.argv) > 2 else None
    password = sys.argv[3] if len(sys.argv) > 3 else None
    
    print(f"🎯 VolleyballLife Playwright Scraper")
    print(f"Target URL: {bracket_url}")
    
    async with VBLPlaywrightScraper(headless=True) as scraper:
        # Login if credentials provided
        if username and password:
            login_success = await scraper.login(username, password)
            if not login_success:
                print("❌ Login failed, continuing without authentication")
        else:
            print("🔓 No credentials provided, proceeding without login")
            
        # Scan the bracket
        result = await scraper.scan_bracket_url(bracket_url)
        
        # Save results to JSON file
        output_file = Path("bracket_scan_results.json")
        with open(output_file, 'w') as f:
            json.dump(result, f, indent=2)
        print(f"💾 Results saved to {output_file}")
        
        # Print summary
        if result['status'] == 'success':
            print(f"🎉 Scan completed successfully!")
            print(f"   • Found {result['match_count']} matches")
            print(f"   • Results saved to {output_file}")
        else:
            print(f"💥 Scan failed: {result.get('error', 'Unknown error')}")


if __name__ == "__main__":
    asyncio.run(main())