#!/usr/bin/env python3
"""
VolleyballLife Precise Scraper
Follows the exact three-phase workflow from screenshot analysis
"""

import asyncio
import json
import sys
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional

from vbl_playwright_scraper import VBLPlaywrightScraper


class VBLPreciseScraper(VBLPlaywrightScraper):
    """Precise scraper using exact selectors from VBL inspection"""
    
    async def three_phase_bracket_scan(self, bracket_url: str, username: str = None, password: str = None) -> Dict:
        """
        Execute the three-phase workflow:
        Phase 1: Find all match containers on main bracket
        Phase 2: Click each match and scrape match card data  
        Phase 3: Extract API URL from VMIX button
        """
        try:
            print(f"🎯 Starting three-phase bracket scan: {bracket_url}")
            
            # Login if credentials provided
            if username and password:
                print("🔐 Phase 0: Logging in...")
                login_success = await self.login(username, password)
                if not login_success:
                    print("❌ Login failed - continuing anyway")
            
            # Navigate to bracket page
            print("📍 Navigating to bracket page...")
            await self.page.goto(bracket_url)
            await self.page.wait_for_load_state('networkidle')
            
            # Execute three-phase workflow
            matches_data = await self.execute_three_phases()
            
            result = {
                'url': bracket_url,
                'timestamp': datetime.now().isoformat(),
                'total_matches': len(matches_data),
                'matches': matches_data,
                'status': 'success' if matches_data else 'no_matches'
            }
            
            print(f"✅ Three-phase scan complete - extracted {len(matches_data)} matches")
            return result
            
        except Exception as e:
            print(f"❌ Error in three-phase scan: {e}")
            return {
                'url': bracket_url,
                'timestamp': datetime.now().isoformat(),
                'error': str(e),
                'status': 'error'
            }
    
    async def execute_three_phases(self) -> List[Dict]:
        """Execute the three-phase extraction workflow"""
        
        # Phase 1: Find all match containers
        print("\n🏆 PHASE 1: Interacting with the Main Bracket")
        match_containers = await self.phase_1_find_match_containers()
        
        if not match_containers:
            print("❌ No match containers found")
            return []
        
        print(f"✅ Phase 1 complete - found {len(match_containers)} match containers")
        
        # Phase 2 & 3: Process each match container
        matches_data = []
        for i, container in enumerate(match_containers):
            try:
                print(f"\n🎯 Processing match {i + 1}/{len(match_containers)}...")
                
                # Phase 2: Open and scrape match card
                match_data = await self.phase_2_open_and_scrape_card(container, i)
                
                if match_data:
                    # Phase 3: Extract API URL
                    api_url = await self.phase_3_extract_api_url()
                    if api_url:
                        match_data['api_url'] = api_url
                    
                    matches_data.append(match_data)
                    print(f"✅ Match {i + 1} processed successfully")
                else:
                    print(f"⚠️ Match {i + 1} - no data extracted")
                
                # Close any open overlays
                await self.close_overlay()
                await asyncio.sleep(0.6)  # 0.6 second pause between matches for stability
                
            except Exception as e:
                print(f"❌ Error processing match {i + 1}: {e}")
                await self.close_overlay()
                continue
        
        return matches_data
    
    async def phase_1_find_match_containers(self) -> List:
        """
        Phase 1: Find all Match Containers
        Try multiple selectors to find match elements
        """
        print("🔍 Phase 1: Finding match containers on bracket page...")
        
        try:
            # First, let's see what's actually on the page
            print("🔍 Debugging: Checking page content...")
            page_title = await self.page.title()
            current_url = self.page.url
            print(f"   📄 Page title: {page_title}")
            print(f"   🌐 Current URL: {current_url}")
            
            # Try multiple possible selectors for match containers
            possible_selectors = [
                'div.div-match-card',
                '.match-card',
                '.div-match-card', 
                '[class*="match"]',
                '[class*="card"]',
                '.bracket-match',
                'div[class*="match"]',
                '.match-container',
                'div[data-match]',
                '.game-card'
            ]
            
            match_containers = []
            successful_selector = None
            
            for selector in possible_selectors:
                try:
                    print(f"🔍 Trying selector: {selector}")
                    
                    # Wait a bit for elements to load
                    await asyncio.sleep(1.2)
                    
                    elements = await self.page.locator(selector).all()
                    print(f"   Found {len(elements)} elements with {selector}")
                    
                    if elements:
                        # Check if any are actually visible, clickable, and not in left side menu
                        visible_elements = []
                        for i, element in enumerate(elements):
                            try:
                                if await element.is_visible():
                                    # Get element position to avoid left side menu
                                    bounding_box = await element.bounding_box()
                                    if bounding_box:
                                        x_position = bounding_box['x']
                                        # Skip elements that are too far left (likely in side menu)
                                        if x_position < 200:  # Elements with x < 200px are likely in left menu
                                            print(f"   ⚠️ Skipping element at x={x_position} (too far left - likely side menu)")
                                            continue
                                    
                                    text = await element.text_content() or ""
                                    if len(text.strip()) > 5:  # Has some content
                                        visible_elements.append(element)
                                        position_info = f" at x={bounding_box['x']:.0f}" if bounding_box else ""
                                        print(f"   ✅ Visible match {i + 1}{position_info}: {text[:80]}...")
                            except Exception as e:
                                print(f"   ⚠️ Error checking element {i + 1}: {e}")
                        
                        if visible_elements:
                            match_containers = visible_elements
                            successful_selector = selector
                            break
                        
                except Exception as e:
                    print(f"   ❌ Selector {selector} failed: {e}")
                    continue
            
            if match_containers:
                print(f"✅ Found {len(match_containers)} match containers using selector: {successful_selector}")
                return match_containers
            else:
                # If no matches found, let's get a page screenshot and HTML dump for debugging
                print("❌ No match containers found with any selector")
                print("🔍 Getting page info for debugging...")
                
                # Get all elements with 'match' in their class or id
                all_match_elements = await self.page.locator('[class*="match"], [id*="match"]').all()
                print(f"   Found {len(all_match_elements)} elements with 'match' in class/id")
                
                # Get all clickable elements
                all_clickable = await self.page.locator('div, button, a').all()
                clickable_count = 0
                for elem in all_clickable:
                    if await elem.is_visible():
                        clickable_count += 1
                print(f"   Found {clickable_count} visible clickable elements")
                
                # Save page content for debugging
                page_content = await self.page.content()
                with open('debug_page.html', 'w') as f:
                    f.write(page_content)
                print("   💾 Page HTML saved to debug_page.html")
                
                return []
            
        except Exception as e:
            print(f"❌ Phase 1 failed with error: {e}")
            return []
    
    async def phase_2_open_and_scrape_card(self, match_container, index: int) -> Optional[Dict]:
        """
        Phase 2: Opening and Scraping the Match Card
        1. Click the match container
        2. Wait for overlay: div.v-overlay-container
        3. Extract data from card
        """
        print("🏆 PHASE 2: Opening and Scraping the Match Card")
        
        try:
            # Step 1: Click the match container
            print("👆 Step 1: Clicking the match container...")
            await match_container.click()
            await asyncio.sleep(0.3)  # Brief delay after click for stability
            
            # Step 2: Wait for the overlay to appear
            print("⏳ Step 2: Waiting for overlay (div.v-overlay-container)...")
            await self.page.wait_for_selector('div.v-overlay-container', timeout=5000)
            
            # Get the overlay container
            overlay = self.page.locator('div.v-overlay-container').first
            
            if not await overlay.is_visible():
                print("❌ Overlay not visible")
                return None
            
            print("✅ Match card overlay is visible")
            
            # Step 3: Extract initial data from the card
            print("📊 Step 3: Extracting initial data...")
            match_data = await self.extract_card_data(overlay, index)
            
            return match_data
            
        except Exception as e:
            print(f"❌ Phase 2 failed: {e}")
            return None
    
    async def extract_card_data(self, overlay, index: int) -> Dict:
        """Extract data from the match card overlay"""
        match_data = {
            'index': index,
            'match_number': None,
            'time': None,
            'court': None,
            'team_names': [],
            'header_info': None
        }
        
        try:
            # Extract Match Header Info (Match #, Time, Court) from div.v-card-title
            print("🔍 Extracting header info from div.v-card-title...")
            title_element = overlay.locator('div.v-card-title').first
            if await title_element.is_visible():
                header_text = await title_element.text_content() or ""
                match_data['header_info'] = header_text.strip()
                print(f"   📋 Header: {header_text}")
                
                # Parse header for match number, time, court
                import re
                
                # Match number and time - handle complex concatenated formats
                # Examples from JSON: "Match 131:00PM", "Match 273:00PM", "Match 285:00PM"
                match_patterns = [
                    # Complex cases like "Match 273:00PM" -> Match #27, 3:00PM
                    r'match\s*(\d{2})(\d):(\d{2})([AP]M)',     # Match 27 3:00PM -> Match #27, 3:00PM
                    r'match\s*(\d{2})(\d{1,2}):(\d{2})([AP]M)', # Match 28 5:00PM -> Match #28, 5:00PM
                    # Simple cases like "Match 49:00AM" -> Match #4, 9:00AM  
                    r'match\s*(\d)(\d{1,2}):(\d{2})([AP]M)',   # Match 4 9:00AM -> Match #4, 9:00AM
                    # Medium cases like "Match 310:00AM" -> Match #3, 10:00AM
                    r'match\s*(\d{1,2})(\d{1,2}):(\d{2})([AP]M)', # Match 3 10:00AM -> Match #3, 10:00AM
                    r'match\s*(\d+)',  # Fallback to original
                ]
                
                for pattern_idx, pattern in enumerate(match_patterns):
                    match_num = re.search(pattern, header_text, re.IGNORECASE)
                    if match_num:
                        print(f"   🔧 Match pattern #{pattern_idx + 1} matched: {pattern}")
                        if len(match_num.groups()) >= 4:  # Concatenated format with time
                            match_number = match_num.group(1)
                            time_hour = match_num.group(2)
                            time_minute = match_num.group(3)
                            am_pm = match_num.group(4)
                            
                            # Validate hour makes sense
                            hour_int = int(time_hour)
                            if 1 <= hour_int <= 12:  # Valid 12-hour format
                                corrected_time = f"{time_hour}:{time_minute}{am_pm}"
                                match_data['match_number'] = match_number
                                match_data['time'] = corrected_time
                                print(f"   🔧 Parsed: Match #{match_number} at {corrected_time} from '{header_text}'")
                                break
                            elif hour_int <= 24:  # Could be 24-hour, try extracting last digit
                                corrected_hour = hour_int % 10
                                if corrected_hour == 0:
                                    corrected_hour = 10
                                corrected_time = f"{corrected_hour}:{time_minute}{am_pm}"
                                match_data['match_number'] = match_number
                                match_data['time'] = corrected_time
                                print(f"   🔧 Corrected hour: Match #{match_number} at {corrected_time} from '{header_text}'")
                                break
                        else:
                            # Simple match number only
                            match_data['match_number'] = match_num.group(1)
                            print(f"   📝 Simple match: #{match_num.group(1)}")
                            break
                
                # Time fallback - only if not already extracted from match number
                if not match_data.get('time'):
                    print("   ⏰ Attempting fallback time extraction...")
                    time_patterns = [
                        r'(\d{1,2}:\d{2}\s*[AP]M)',  # 10:30AM, 2:15PM
                        r'(\d{1,2}[AP]M)',           # 10AM, 2PM
                        r'(\d{1,2}:\d{2})',          # 10:30, 14:15
                    ]
                    
                    for pattern in time_patterns:
                        time_matches = re.findall(pattern, header_text, re.IGNORECASE)
                        for time_str in time_matches:
                            # Simple validation for fallback
                            if ':' in time_str and len(time_str) <= 8:
                                match_data['time'] = time_str
                                print(f"   ⏰ Fallback time: {time_str}")
                                break
                            elif re.match(r'\d{1,2}[AP]M', time_str):
                                match_data['time'] = time_str
                                print(f"   ⏰ Fallback time: {time_str}")
                                break
                        if match_data.get('time'):
                            break
                
                # Court  
                court_match = re.search(r'court\s*([^\s]+)', header_text, re.IGNORECASE)
                if court_match:
                    match_data['court'] = court_match.group(1)
            
            # Extract Team Names - Use regex patterns on full text to avoid selector issues
            print("🔍 Extracting team names using regex patterns...")
            
            try:
                # Get the full overlay text
                full_text = await overlay.text_content() or ""
                print(f"   📝 Raw overlay text (first 200 chars): {full_text[:200]}...")
                print(f"   📝 Full overlay text length: {len(full_text)} characters")
                
                # First, try to parse player pairs from the corrupted text
                # Pattern: "Name1 / Name2" format (most common in volleyball)
                player_pair_patterns = [
                    # Match pairs like "Peter Connole / Steven Roschitz" 
                    r'([A-Z][a-z]+\s+[A-Z][a-z]+)\s*/\s*([A-Z][a-z]+\s+[A-Z][a-z]+)',
                    # Match pairs with middle initials: "John A. Smith / Mary B. Jones"
                    r'([A-Z][a-z]+\s+[A-Z]\.?\s+[A-Z][a-z]+)\s*/\s*([A-Z][a-z]+\s+[A-Z]\.?\s+[A-Z][a-z]+)',
                    # Match single names in pairs: "John / Mary"
                    r'([A-Z][a-z]{2,})\s*/\s*([A-Z][a-z]{2,})',
                ]
                
                found_teams = []
                for pattern_idx, pattern in enumerate(player_pair_patterns):
                    pairs = re.findall(pattern, full_text)
                    print(f"   🔍 Pattern #{pattern_idx + 1} found {len(pairs)} potential team pairs")
                    for pair in pairs:
                        team_name = f"{pair[0]} / {pair[1]}"
                        if len(team_name) < 50 and team_name not in found_teams:  # Reasonable length
                            found_teams.append(team_name)
                            print(f"   🏐 Extracted team: '{team_name}'")
                
                # If we found teams, use the first two as our matchup
                if found_teams:
                    match_data['team_names'] = found_teams[:2]
                    print(f"   ✅ Using teams: {match_data['team_names']}")
                
                # Fallback: Try to extract from the mess by looking for patterns
                if not match_data['team_names']:
                    print("🔍 Fallback: parsing from corrupted text...")
                    
                    # First check if this is a bracket advancement match (Match X Winner format)
                    bracket_pattern = r'Match\s+(\d+)\s+Winner.*?Match\s+(\d+)\s+Winner'
                    bracket_match = re.search(bracket_pattern, full_text, re.IGNORECASE)
                    if bracket_match:
                        match1_num = bracket_match.group(1)
                        match2_num = bracket_match.group(2)
                        match_data['team_names'] = [f"Match {match1_num} Winner", f"Match {match2_num} Winner"]
                        print(f"   ✅ Bracket match: 'Match {match1_num} Winner' vs 'Match {match2_num} Winner'")
                    
                    # Look for the pattern in your JSON: "TeamSet 1Set 2Set 3 NAME1 / NAME2 ... NAME3 / NAME4 Ref: ..."
                    if not match_data['team_names']:
                        # Extract everything between the initial mess and "Ref:"
                        ref_match = re.search(r'TeamSet.*?(\w+\s+\w+\s*/\s*\w+\s+\w+).*?(\w+\s+\w+\s*/\s*\w+\s+\w+).*?Ref:', full_text)
                        if ref_match:
                            team1 = ref_match.group(1).strip()
                            team2 = ref_match.group(2).strip()
                            match_data['team_names'] = [team1, team2]
                            print(f"   ✅ Extracted from corrupted text: '{team1}' vs '{team2}'")
                    
                    # Another fallback: look for just name patterns without the structure
                    if not match_data['team_names']:
                        # Find all potential player names (First Last format)
                        name_pattern = r'\b([A-Z][a-z]+\s+[A-Z][a-z]+)\b'
                        potential_names = re.findall(name_pattern, full_text)
                        # Filter out UI elements
                        potential_names = [name for name in potential_names if name not in ['Quick Settings', 'Add Courts', 'Team Search']]
                        
                        if len(potential_names) >= 4:  # Need at least 4 names for 2 teams of 2
                            # Group them into pairs
                            team1 = f"{potential_names[0]} / {potential_names[1]}"
                            team2 = f"{potential_names[2]} / {potential_names[3]}"
                            match_data['team_names'] = [team1, team2]
                            print(f"   ✅ Constructed teams from names: '{team1}' vs '{team2}'")
                        elif len(potential_names) >= 2:
                            # Use first two as single names
                            match_data['team_names'] = potential_names[:2]
                            print(f"   ✅ Using individual names: {match_data['team_names']}")
                
                # Final fallback: try simple "vs" or "versus" splitting
                if not match_data['team_names']:
                    print("🔍 Final fallback: looking for vs patterns...")
                    # Remove the TeamSet noise and look for clean parts
                    clean_text = re.sub(r'TeamSet\s*\d+', '', full_text)
                    clean_text = re.sub(r'Set\s*\d+', '', clean_text)
                    
                    vs_patterns = [
                        r'([A-Za-z\s/]+?)\s+(?:vs?\.?|versus)\s+([A-Za-z\s/]+?)(?:\s+Ref:|$)',
                        r'([A-Z][a-z]+.*?/.*?[A-Z][a-z]+).*?([A-Z][a-z]+.*?/.*?[A-Z][a-z]+)'
                    ]
                    
                    for pattern in vs_patterns:
                        match = re.search(pattern, clean_text, re.IGNORECASE)
                        if match:
                            team1 = match.group(1).strip()
                            team2 = match.group(2).strip()
                            if 5 < len(team1) < 50 and 5 < len(team2) < 50:
                                match_data['team_names'] = [team1, team2]
                                print(f"   ✅ VS pattern match: '{team1}' vs '{team2}'")
                                break
                                
            except Exception as e:
                print(f"   ⚠️ Team extraction failed: {e}")
                
                # Absolute fallback - just use generic names if we can detect this is a valid match
                if 'match' in full_text.lower() and 'court' in full_text.lower():
                    match_num = match_data.get('match_number', '?')
                    match_data['team_names'] = [f"Team A (Match {match_num})", f"Team B (Match {match_num})"]
                    print(f"   🔧 Using fallback team names for match {match_num}")
            
            # Set team1 and team2 from team_names list
            if len(match_data['team_names']) >= 1:
                match_data['team1'] = match_data['team_names'][0]
            if len(match_data['team_names']) >= 2:
                match_data['team2'] = match_data['team_names'][1]
            
            print(f"📊 Extracted: Match#{match_data.get('match_number')}, "
                  f"Time={match_data.get('time')}, Court={match_data.get('court')}, "
                  f"Teams={len(match_data['team_names'])}")
            
        except Exception as e:
            print(f"⚠️ Error extracting card data: {e}")
        
        return match_data
    
    async def phase_3_extract_api_url(self) -> Optional[str]:
        """
        Phase 3: Revealing and Extracting the API URL
        1. Click the VMIX button
        2. Wait for API URL link to appear
        3. Extract the href attribute
        """
        print("🏆 PHASE 3: Revealing and Extracting the API URL")
        
        try:
            # Step 1: Click the VMIX button
            print("👆 Step 1: Looking for VMIX button...")
            vmix_selectors = [
                'button:has-text("Vmix")',
                'button:has-text("vMix")', 
                'button:has-text("VMIX")',
                '[class*="vmix"]'
            ]
            
            vmix_button = None
            for selector in vmix_selectors:
                try:
                    buttons = await self.page.locator(selector).all()
                    print(f"   Found {len(buttons)} buttons matching {selector}")
                    
                    for button in buttons:
                        if await button.is_visible() and await button.is_enabled():
                            # Make sure it's actually a VMIX button by checking text
                            button_text = await button.text_content() or ""
                            if any(vmix_word in button_text.lower() for vmix_word in ['vmix', 'v-mix']):
                                vmix_button = button
                                print(f"✅ Found VMIX button: '{button_text}' with selector: {selector}")
                                break
                    
                    if vmix_button:
                        break
                        
                except Exception as e:
                    print(f"   ⚠️ Selector {selector} failed: {e}")
                    continue
            
            if not vmix_button:
                print("❌ VMIX button not found")
                return None
            
            print("👆 Clicking VMIX button to reveal API URL...")
            # Use force click to avoid issues with overlapping elements
            await vmix_button.click(force=True)
            print("✅ VMIX button clicked successfully - waiting for API URL")
            
            # Step 2: Wait for the API URL link to appear
            print("⏳ Step 2: Scanning page for API URL links after button click...")
            await asyncio.sleep(2.0)  # Longer pause for content to load
            
            # Step 3: Extract the API URL using comprehensive selectors
            print("🔍 Step 3: Looking for API URL link...")
            
            # First, let's see what actually appeared after clicking vMix
            print("🔍 Debugging: Checking for any new links that appeared...")
            all_links = await self.page.locator('a').all()
            found_api_urls = []
            
            for i, link in enumerate(all_links[:15]):  # Check first 15 links
                try:
                    href = await link.get_attribute('href')
                    text = await link.text_content() or ""
                    if href and ('api' in href.lower() or 'volleyballlife.com/api' in href or 'google.com' in href):
                        print(f"   🔗 Found potential API link {i+1}: {href} (text: '{text[:50]}')")
                        found_api_urls.append(href)
                except Exception:
                    continue
            
            # Also check for input fields that might contain API URLs
            print("🔍 Checking for input fields with API URLs...")
            all_inputs = await self.page.locator('input').all()
            for i, input_elem in enumerate(all_inputs[:10]):  # Check first 10 inputs
                try:
                    value = await input_elem.get_attribute('value') or ""
                    placeholder = await input_elem.get_attribute('placeholder') or ""
                    input_type = await input_elem.get_attribute('type') or ""
                    
                    if value and ('api' in value.lower() or 'volleyballlife.com' in value or 'http' in value):
                        print(f"   📝 Found potential API input #{i+1}: value='{value[:100]}'...")
                        if 'api' in value:
                            found_api_urls.append(value)
                    elif placeholder and 'api' in placeholder.lower():
                        print(f"   📝 Found API placeholder {i+1}: placeholder='{placeholder}'")
                except Exception:
                    continue
            
            # Check text areas too
            print("🔍 Checking for text areas with API URLs...")
            all_textareas = await self.page.locator('textarea').all()
            for i, textarea in enumerate(all_textareas[:5]):
                try:
                    value = await textarea.get_attribute('value') or await textarea.text_content() or ""
                    if value and ('api' in value.lower() or 'volleyballlife.com' in value or 'http' in value):
                        print(f"   📝 Found potential API textarea {i+1}: value='{value[:100]}'")
                        if 'api' in value:
                            found_api_urls.append(value)
                except Exception:
                    continue
            
            # If we found any potential API URLs, return the first one
            if found_api_urls:
                api_url = found_api_urls[0]
                print(f"✅ Found API URL: {api_url}")
                return api_url
            
            # NEW: Look for API URL as text content (from screenshot analysis)
            print("🔍 Looking for API URL as text content...")
            try:
                # Get all text content from the page and look for API URLs
                page_content = await self.page.content()
                
                # Look for API URL patterns in the text
                api_url_patterns = [
                    r'(https://api\.volleyballlife\.com/api/v1\.0/matches/\d+/vmix\?[^"\s]+)',
                    r'(https://api\.volleyballlife\.com[^"\s]+)',
                    r'(api\.volleyballlife\.com/[^"\s]+)',
                ]
                
                import re
                for pattern in api_url_patterns:
                    matches = re.findall(pattern, page_content, re.IGNORECASE)
                    if matches:
                        api_url = matches[0]
                        if not api_url.startswith('http'):
                            api_url = 'https://' + api_url
                        print(f"✅ Found API URL in text content: {api_url}")
                        return api_url
                
                # Also try to find highlighted/selected text elements
                highlighted_selectors = [
                    'div[style*="background"]',  # Highlighted divs
                    '.selected',
                    '[class*="highlight"]',
                    '[class*="selected"]',
                    'div:has-text("api.volleyballlife.com")',
                ]
                
                for selector in highlighted_selectors:
                    try:
                        elements = await self.page.locator(selector).all()
                        for element in elements:
                            text = await element.text_content() or ""
                            if 'api.volleyballlife.com' in text:
                                # Extract URL from the text
                                url_match = re.search(r'(https?://[^\s]+)', text)
                                if url_match:
                                    api_url = url_match.group(1)
                                    print(f"✅ Found API URL in highlighted element: {api_url}")
                                    return api_url
                    except Exception:
                        continue
                        
            except Exception as e:
                print(f"⚠️ Text content search failed: {e}")
            
            # Fallback to original selectors
            print("🔍 Falling back to element selectors...")
            api_selectors = [
                'a[href*="api.volleyballlife.com"]',
                'a[href*="api"]',
                'input[value*="api.volleyballlife.com"]',
                'input[value*="api"]',
                'a[href*="volleyballlife.com/api"]',
                'a[href*="google.com/url"][href*="api"]',
                '[class*="api"]',
                '[id*="api"]',
                'textarea',  # API URLs sometimes appear in text areas
                '.v-overlay a',  # Links within overlays
                '.v-card a'  # Links within cards
            ]
            
            for selector in api_selectors:
                try:
                    elements = await self.page.locator(selector).all()
                    print(f"   🔍 Checking {len(elements)} elements with selector: {selector}")
                    
                    for element in elements:
                        try:
                            if not await element.is_visible():
                                continue
                                
                            # Try both href and value attributes
                            api_url = await element.get_attribute('href') or await element.get_attribute('value') or await element.text_content() or ""
                            api_url = api_url.strip()
                            
                            if api_url and ('api' in api_url.lower() or 'volleyballlife.com' in api_url):
                                # If it's a Google redirect URL, extract the actual API URL
                                if 'google.com/url' in api_url and 'q=' in api_url:
                                    import urllib.parse
                                    try:
                                        parsed = urllib.parse.parse_qs(urllib.parse.urlparse(api_url).query)
                                        if 'q' in parsed:
                                            api_url = parsed['q'][0]
                                    except:
                                        pass
                                
                                print(f"✅ Found API URL: {api_url}")
                                return api_url
                                
                        except Exception as e:
                            print(f"      ⚠️ Error checking element: {e}")
                            continue
                            
                except Exception as e:
                    print(f"   ⚠️ Selector {selector} failed: {e}")
                    continue
            
            # If we still can't find API URL, take a screenshot for debugging
            try:
                screenshot_path = f"debug_vmix_click_{datetime.now().strftime('%H%M%S')}.png"
                await self.page.screenshot(path=screenshot_path)
                print(f"📸 Saved debug screenshot to {screenshot_path}")
            except Exception:
                pass
                
            print("❌ API URL not found after clicking VMIX")
            return None
            
        except Exception as e:
            print(f"❌ Phase 3 failed: {e}")
            return None
    
    async def close_overlay(self):
        """Close any open match card overlays by clicking outside the modal"""
        try:
            print("🔄 Closing match card overlay...")
            
            # Get viewport dimensions to calculate bottom-right area
            viewport_size = await self.page.viewport_size()
            viewport_width = viewport_size['width'] if viewport_size else 1280
            viewport_height = viewport_size['height'] if viewport_size else 720
            
            # Click in bottom-right area of bracket page (avoiding left side menu)
            # Use coordinates that are mostly in bottom-right but not at the very edge
            background_click_points = [
                (int(viewport_width * 0.75), int(viewport_height * 0.8)),   # Bottom-right area (75%, 80%)
                (int(viewport_width * 0.8), int(viewport_height * 0.7)),    # Right side, lower middle
                (int(viewport_width * 0.7), int(viewport_height * 0.9)),    # Lower right, closer to bottom
                (int(viewport_width * 0.85), int(viewport_height * 0.6)),   # Right side, middle
                (int(viewport_width * 0.6), int(viewport_height * 0.85)),   # Center-right, lower
                (int(viewport_width * 0.9), int(viewport_height * 0.5))     # Far right, middle
            ]
            
            print(f"   📐 Using viewport {viewport_width}x{viewport_height} for background clicks")
            
            overlay_closed = False
            
            for x, y in background_click_points:
                try:
                    print(f"   🖱️  Clicking background at ({x}, {y}) to close overlay...")
                    await self.page.mouse.click(x, y)
                    await asyncio.sleep(0.3)
                    
                    # Check if overlay is still visible
                    overlay_still_visible = await self.page.locator('div.v-overlay-container').is_visible()
                    if not overlay_still_visible:
                        print("   ✅ Overlay closed successfully")
                        overlay_closed = True
                        break
                        
                except Exception as e:
                    print(f"   ⚠️ Click at ({x}, {y}) failed: {e}")
                    continue
            
            if not overlay_closed:
                # Try Escape key as fallback
                print("   🔄 Trying Escape key...")
                await self.page.keyboard.press('Escape')
                await asyncio.sleep(0.5)
                
                # Try close buttons as last resort
                close_selectors = [
                    'button:has-text("×")',
                    'button[aria-label="Close"]',
                    '.v-overlay button[class*="close"]',
                    '[class*="close-btn"]'
                ]
                
                for selector in close_selectors:
                    try:
                        close_btn = self.page.locator(selector).first
                        if await close_btn.is_visible():
                            print(f"   🖱️  Clicking close button: {selector}")
                            await close_btn.click()
                            await asyncio.sleep(0.3)
                            break
                    except Exception:
                        continue
                        
            # Final wait to ensure overlay is fully closed
            await asyncio.sleep(0.6)
            print("✅ Match card close sequence complete")
            
        except Exception as e:
            print(f"⚠️ Error in close_overlay: {e}")
            # Always try Escape as absolute fallback
            try:
                await self.page.keyboard.press('Escape')
                await asyncio.sleep(0.3)
            except:
                pass


async def main():
    """Main execution function"""
    if len(sys.argv) < 2:
        print("Usage: python3 vbl_precise_scraper.py <bracket_url> [username] [password]")
        print("Example: python3 vbl_precise_scraper.py 'https://volleyballlife.com/event/123/brackets' user@email.com password")
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
    
    print(f"🎯 VolleyballLife Precise Scraper")
    print(f"🌐 Target URL: {bracket_url}")
    print(f"🔐 Login: {'Yes' if username else 'No'}")
    print(f"📋 Using exact selectors from VBL inspection")
    
    async with VBLPreciseScraper(headless=False, timeout=15000) as scraper:
        # Execute three-phase scan
        result = await scraper.three_phase_bracket_scan(bracket_url, username, password)
        
        # Save results
        output_file = Path("precise_bracket_results.json")
        with open(output_file, 'w') as f:
            json.dump(result, f, indent=2)
        print(f"\n💾 Results saved to {output_file}")
        
        # Print summary
        if result['status'] == 'success':
            print(f"\n🎉 Three-phase scan successful!")
            print(f"   📊 Found {result['total_matches']} matches")
            
            # Show sample of extracted data
            for i, match in enumerate(result['matches'][:3]):
                team1 = match.get('team1', '?')
                team2 = match.get('team2', '?') 
                court = match.get('court', '?')
                time = match.get('time', '?')
                api_url = '✅' if match.get('api_url') else '❌'
                
                print(f"   🏐 Match {i+1}: {team1} vs {team2}")
                print(f"      📍 Court: {court}, ⏰ Time: {time}, 🔗 API: {api_url}")
                
            if len(result['matches']) > 3:
                print(f"   ➕ ... and {len(result['matches']) - 3} more matches")
                
        else:
            print(f"💥 Scan failed: {result.get('error', 'Unknown error')}")


if __name__ == "__main__":
    asyncio.run(main())