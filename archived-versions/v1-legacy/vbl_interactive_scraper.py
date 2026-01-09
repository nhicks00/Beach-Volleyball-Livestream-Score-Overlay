#!/usr/bin/env python3
"""
VolleyballLife Interactive Bracket Scraper
Signs in, clicks each match to open match cards, and extracts detailed match data
"""

import asyncio
import json
import sys
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional

from vbl_playwright_scraper import VBLPlaywrightScraper


class VBLInteractiveScraper(VBLPlaywrightScraper):
    """Interactive scraper that clicks matches to extract detailed data"""
    
    async def interactive_bracket_scan(self, bracket_url: str, username: str = None, password: str = None) -> Dict:
        """
        Perform interactive bracket scan by clicking each match
        Returns detailed match data with API URLs
        """
        try:
            print(f"🎯 Starting interactive bracket scan: {bracket_url}")
            
            # Step 1: Login if credentials provided
            if username and password:
                print("🔐 Logging in...")
                login_success = await self.login(username, password)
                if not login_success:
                    print("❌ Login failed - continuing anyway, some data may be missing")
            else:
                print("🔓 No credentials provided - some data may be missing")
            
            # Step 2: Navigate to bracket page
            print("📍 Navigating to bracket page...")
            await self.page.goto(bracket_url)
            await self.page.wait_for_load_state('networkidle')
            
            # Step 3: Wait for bracket to load and find matches
            print("⏳ Waiting for bracket to load...")
            matches_data = await self.find_and_process_matches()
            
            result = {
                'url': bracket_url,
                'timestamp': datetime.now().isoformat(),
                'total_matches': len(matches_data),
                'matches': matches_data,
                'status': 'success' if matches_data else 'no_matches'
            }
            
            print(f"✅ Interactive scan complete - found {len(matches_data)} matches")
            return result
            
        except Exception as e:
            print(f"❌ Error in interactive scan: {e}")
            return {
                'url': bracket_url,
                'timestamp': datetime.now().isoformat(),
                'error': str(e),
                'status': 'error'
            }
    
    async def find_and_process_matches(self) -> List[Dict]:
        """Find all matches in bracket and process each one"""
        matches_data = []
        
        try:
            # Wait for bracket content to appear
            print("🔍 Looking for bracket matches...")
            
            # Multiple selectors to find match elements
            match_selectors = [
                '[class*="match"]',
                '[class*="game"]', 
                '[class*="bracket"] .team',
                '.bracket-match',
                '.match-card',
                '[data-match-id]',
                'div:has-text("vs")',
                '[class*="team"]:has-text("vs")',
                'div[role="button"]'
            ]
            
            match_elements = []
            
            # Try each selector to find clickable match elements
            for selector in match_selectors:
                try:
                    await self.page.wait_for_selector(selector, timeout=3000)
                    elements = await self.page.locator(selector).all()
                    
                    if elements:
                        print(f"📋 Found {len(elements)} elements with selector: {selector}")
                        
                        # Filter for elements that look like matches
                        for element in elements:
                            text = await element.text_content() or ""
                            if len(text.strip()) > 5 and any(keyword in text.lower() for keyword in ['vs', 'v ', ' - ', 'court', 'match']):
                                match_elements.append(element)
                        
                        if match_elements:
                            print(f"✅ Using selector: {selector} - found {len(match_elements)} match elements")
                            break
                            
                except Exception:
                    continue
            
            # If no specific match selectors work, try finding clickable elements with team-like text
            if not match_elements:
                print("🔄 No match elements found, trying text-based approach...")
                match_elements = await self.find_matches_by_content()
            
            # Process each match element
            if match_elements:
                print(f"🎮 Processing {len(match_elements)} matches...")
                
                for i, match_element in enumerate(match_elements):
                    try:
                        print(f"\n🎯 Processing match {i + 1}/{len(match_elements)}...")
                        match_data = await self.process_single_match(match_element, i)
                        
                        if match_data:
                            matches_data.append(match_data)
                            print(f"✅ Match {i + 1} processed successfully")
                        else:
                            print(f"⚠️ Match {i + 1} - no data extracted")
                            
                        # Small delay between matches to avoid overwhelming the site
                        await asyncio.sleep(0.5)
                        
                    except Exception as e:
                        print(f"❌ Error processing match {i + 1}: {e}")
                        continue
            else:
                print("❌ No match elements found on the page")
            
        except Exception as e:
            print(f"❌ Error finding matches: {e}")
        
        return matches_data
    
    async def find_matches_by_content(self) -> List:
        """Fallback: find matches by looking for elements containing team names or 'vs'"""
        match_elements = []
        
        try:
            # Look for any clickable elements that contain match-like text
            all_clickable = await self.page.locator('div, span, button, a').all()
            
            for element in all_clickable:
                try:
                    text = await element.text_content() or ""
                    text = text.strip()
                    
                    # Check if this looks like a match
                    if (len(text) > 5 and len(text) < 100 and 
                        any(indicator in text.lower() for indicator in ['vs', ' v ', ' - ']) and
                        not any(skip in text.lower() for skip in ['copyright', 'privacy', 'terms', 'login', 'signup'])):
                        
                        # Check if element is clickable
                        if await element.is_visible() and await element.is_enabled():
                            match_elements.append(element)
                            
                except Exception:
                    continue
                    
            print(f"📝 Found {len(match_elements)} potential matches by content analysis")
            
        except Exception as e:
            print(f"⚠️ Error in content-based match finding: {e}")
            
        return match_elements
    
    async def process_single_match(self, match_element, index: int) -> Optional[Dict]:
        """Click on a match element and extract detailed data from the match card"""
        try:
            # Get preview info from the match element
            preview_text = await match_element.text_content() or ""
            print(f"🔍 Match preview: {preview_text[:100]}...")
            
            # Click on the match element to open match card
            print("👆 Clicking on match...")
            await match_element.click()
            
            # Wait for match card/modal to appear
            await asyncio.sleep(1)
            
            # Try multiple selectors for match card/modal
            match_card_selectors = [
                '.modal',
                '.match-detail', 
                '.match-card',
                '[class*="modal"]',
                '[class*="dialog"]',
                '[class*="popup"]',
                '[class*="overlay"]'
            ]
            
            match_card = None
            for selector in match_card_selectors:
                try:
                    await self.page.wait_for_selector(selector, timeout=2000)
                    match_card = self.page.locator(selector).first
                    if await match_card.is_visible():
                        print(f"✅ Match card found with selector: {selector}")
                        break
                except:
                    continue
            
            if not match_card:
                print("⚠️ No match card found - extracting what we can from current page")
                match_card = self.page.locator('body')
            
            # Extract match details from the card
            match_data = await self.extract_match_details(match_card, index, preview_text)
            
            # Close the match card if there's a close button
            await self.close_match_card()
            
            return match_data
            
        except Exception as e:
            print(f"❌ Error processing match: {e}")
            # Try to close any open modals
            await self.close_match_card()
            return None
    
    async def extract_match_details(self, match_card, index: int, preview_text: str) -> Dict:
        """Extract detailed match information from the match card"""
        match_data = {
            'index': index,
            'preview_text': preview_text,
            'team1': None,
            'team2': None,
            'match_number': None,
            'court': None,
            'start_time': None,
            'api_url': None,
            'vmix_data': None
        }
        
        try:
            # Get all text from the match card
            card_text = await match_card.text_content() or ""
            
            # Extract team names from preview or card
            team_info = self.parse_team_names(preview_text) or self.parse_team_names(card_text)
            if team_info:
                match_data['team1'], match_data['team2'] = team_info
            
            # Look for match number
            import re
            match_num_patterns = [
                r'match\s*#?(\d+)',
                r'game\s*#?(\d+)', 
                r'#(\d+)',
                r'match\s*(\d+)'
            ]
            
            for pattern in match_num_patterns:
                match_num = re.search(pattern, card_text, re.IGNORECASE)
                if match_num:
                    match_data['match_number'] = match_num.group(1)
                    break
            
            # Look for court assignment
            court_patterns = [
                r'court\s*#?(\d+)',
                r'court\s*([a-zA-Z]\d*)',
                r'field\s*(\d+)'
            ]
            
            for pattern in court_patterns:
                court_match = re.search(pattern, card_text, re.IGNORECASE)
                if court_match:
                    match_data['court'] = court_match.group(1)
                    break
            
            # Look for start time
            time_patterns = [
                r'(\d{1,2}:\d{2}\s*[AaPp][Mm])',
                r'(\d{1,2}:\d{2})',
                r'start\s*time[:\s]*(\d{1,2}:\d{2}\s*[AaPp][Mm]?)',
                r'time[:\s]*(\d{1,2}:\d{2}\s*[AaPp][Mm]?)'
            ]
            
            for pattern in time_patterns:
                time_match = re.search(pattern, card_text, re.IGNORECASE)
                if time_match:
                    match_data['start_time'] = time_match.group(1)
                    break
            
            # Look for VMIX button and API URL
            vmix_data = await self.find_vmix_data(match_card)
            if vmix_data:
                match_data['api_url'] = vmix_data.get('api_url')
                match_data['vmix_data'] = vmix_data
            
            print(f"📊 Extracted data: Teams={match_data['team1']} vs {match_data['team2']}, "
                  f"Court={match_data['court']}, Time={match_data['start_time']}, "
                  f"Match#={match_data['match_number']}")
            
        except Exception as e:
            print(f"⚠️ Error extracting match details: {e}")
        
        return match_data
    
    async def find_vmix_data(self, match_card) -> Optional[Dict]:
        """Find and extract VMIX button data including API URL"""
        try:
            # Look for VMIX button
            vmix_selectors = [
                'button:has-text("VMIX")',
                'button:has-text("vMix")',
                '[class*="vmix"]',
                'a:has-text("VMIX")',
                'button[title*="VMIX"]'
            ]
            
            for selector in vmix_selectors:
                try:
                    vmix_button = match_card.locator(selector).first
                    if await vmix_button.is_visible():
                        print("🎮 Found VMIX button, extracting data...")
                        
                        # Try to click VMIX button to reveal API URL
                        await vmix_button.click()
                        await asyncio.sleep(0.5)
                        
                        # Look for API URL in various places
                        api_url = await self.extract_api_url_from_page()
                        
                        if api_url:
                            return {
                                'api_url': api_url,
                                'vmix_found': True
                            }
                        break
                        
                except Exception:
                    continue
                    
        except Exception as e:
            print(f"⚠️ Error finding VMIX data: {e}")
            
        return None
    
    async def extract_api_url_from_page(self) -> Optional[str]:
        """Extract API URL from page after VMIX button click"""
        try:
            # Look for API URLs in various elements
            api_selectors = [
                'input[value*="api"]',
                '[data-api-url]',
                'code:has-text("api")',
                'pre:has-text("api")',
                '.api-url',
                '[class*="url"]'
            ]
            
            for selector in api_selectors:
                try:
                    element = self.page.locator(selector).first
                    if await element.is_visible():
                        # Try different ways to get the URL
                        api_url = (await element.get_attribute('value') or 
                                 await element.get_attribute('data-api-url') or
                                 await element.text_content())
                        
                        if api_url and 'api' in api_url.lower():
                            print(f"✅ Found API URL: {api_url}")
                            return api_url.strip()
                except Exception:
                    continue
            
            # Look for API URLs in page content
            page_content = await self.page.content()
            import re
            api_patterns = [
                r'(https?://[^\s"\'<>]+/api/[^\s"\'<>]+)',
                r'(https?://api\.[^\s"\'<>]+)',
            ]
            
            for pattern in api_patterns:
                matches = re.findall(pattern, page_content, re.IGNORECASE)
                if matches:
                    return matches[0]
                    
        except Exception as e:
            print(f"⚠️ Error extracting API URL: {e}")
            
        return None
    
    def parse_team_names(self, text: str) -> Optional[tuple]:
        """Parse team names from text"""
        if not text:
            return None
            
        import re
        # Various patterns for team vs team
        patterns = [
            r'(.+?)\s+vs?\s+(.+?)(?:\s|$)',
            r'(.+?)\s+-\s+(.+?)(?:\s|$)', 
            r'(.+?)\s+v\s+(.+?)(?:\s|$)',
        ]
        
        for pattern in patterns:
            match = re.search(pattern, text.strip(), re.IGNORECASE)
            if match:
                team1, team2 = match.groups()
                team1, team2 = team1.strip(), team2.strip()
                if len(team1) > 1 and len(team2) > 1:
                    return (team1, team2)
                    
        return None
    
    async def close_match_card(self):
        """Close any open match cards/modals"""
        try:
            close_selectors = [
                'button:has-text("Close")',
                'button:has-text("×")',
                '.close',
                '[class*="close"]',
                'button[aria-label="Close"]',
                '.modal-close'
            ]
            
            for selector in close_selectors:
                try:
                    close_button = self.page.locator(selector).first
                    if await close_button.is_visible():
                        await close_button.click()
                        await asyncio.sleep(0.3)
                        return
                except Exception:
                    continue
                    
            # Try pressing Escape key
            await self.page.keyboard.press('Escape')
            await asyncio.sleep(0.3)
            
        except Exception:
            pass


async def main():
    """Main execution function"""
    if len(sys.argv) < 2:
        print("Usage: python3 vbl_interactive_scraper.py <bracket_url> [username] [password]")
        print("Example: python3 vbl_interactive_scraper.py 'https://volleyballlife.com/event/123/brackets' user@email.com mypassword")
        sys.exit(1)
        
    bracket_url = sys.argv[1]
    username = sys.argv[2] if len(sys.argv) > 2 else None
    password = sys.argv[3] if len(sys.argv) > 3 else None
    
    # Try to load credentials from file if not provided
    if not username:
        creds_file = Path("vbl_credentials.json")
        if creds_file.exists():
            try:
                with open(creds_file, 'r') as f:
                    creds = json.load(f)
                username = creds.get('username')
                password = creds.get('password')
                print("🔑 Using credentials from vbl_credentials.json")
            except:
                pass
    
    print(f"🎯 VolleyballLife Interactive Scraper")
    print(f"Target URL: {bracket_url}")
    print(f"Login: {'Yes' if username else 'No'}")
    
    async with VBLInteractiveScraper(headless=False, timeout=15000) as scraper:
        # Perform interactive scan
        result = await scraper.interactive_bracket_scan(bracket_url, username, password)
        
        # Save results
        output_file = Path("interactive_bracket_results.json")
        with open(output_file, 'w') as f:
            json.dump(result, f, indent=2)
        print(f"\n💾 Results saved to {output_file}")
        
        # Print summary
        if result['status'] == 'success':
            print(f"🎉 Interactive scan successful!")
            print(f"   • Found {result['total_matches']} matches")
            for i, match in enumerate(result['matches'][:3]):  # Show first 3 matches
                print(f"   • Match {i+1}: {match.get('team1', '?')} vs {match.get('team2', '?')} "
                      f"(Court: {match.get('court', '?')}, Time: {match.get('start_time', '?')})")
            if len(result['matches']) > 3:
                print(f"   • ... and {len(result['matches']) - 3} more matches")
        else:
            print(f"💥 Scan failed: {result.get('error', 'Unknown error')}")


if __name__ == "__main__":
    asyncio.run(main())