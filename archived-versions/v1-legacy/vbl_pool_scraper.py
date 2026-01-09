#!/usr/bin/env python3
"""
VolleyballLife Pool Play Scraper
Specialized scraper for pool play pages where matches are displayed open
"""

import asyncio
import json
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from urllib.parse import urlparse, parse_qs

from vbl_playwright_scraper import VBLPlaywrightScraper


class VBLPoolScraper(VBLPlaywrightScraper):
    """Pool play scraper for open match cards"""
    
    def determine_url_type(self, url: str) -> Tuple[str, str]:
        """
        Determine match type and additional info from URL
        Returns: (match_type, additional_info)
        """
        url_lower = url.lower()
        
        if '/pools/' in url_lower:
            # Extract pool number from URL if possible
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
            return "Unknown", ""
    
    async def extract_pool_matches(self, pool_url: str, username: str = None, password: str = None) -> Dict:
        """
        Extract matches from pool play page where all matches are displayed open
        """
        try:
            print(f"🏊 Starting pool play extraction: {pool_url}")
            
            # Determine match type from URL
            match_type, type_detail = self.determine_url_type(pool_url)
            print(f"📋 Detected: {match_type} - {type_detail}")
            
            # Login if credentials provided
            if username and password:
                print("🔐 Logging in...")
                login_success = await self.login(username, password)
                if not login_success:
                    print("❌ Login failed - continuing anyway")
            
            # Navigate to pool page
            print("📍 Navigating to pool page...")
            await self.page.goto(pool_url)
            await self.page.wait_for_load_state('networkidle')
            
            # Wait for page to fully load
            await asyncio.sleep(2.0)
            
            # Extract matches from the open display
            matches_data = await self.extract_open_matches(match_type, type_detail)
            
            result = {
                'url': pool_url,
                'timestamp': datetime.now().isoformat(),
                'total_matches': len(matches_data),
                'matches': matches_data,
                'match_type': match_type,
                'type_detail': type_detail,
                'status': 'success' if matches_data else 'no_matches'
            }
            
            print(f"✅ Pool extraction complete - found {len(matches_data)} matches")
            return result
            
        except Exception as e:
            print(f"❌ Error in pool extraction: {e}")
            return {
                'url': pool_url,
                'timestamp': datetime.now().isoformat(),
                'error': str(e),
                'status': 'error'
            }
    
    async def extract_open_matches(self, match_type: str, type_detail: str) -> List[Dict]:
        """
        Extract match data from open match displays (no need to click cards)
        """
        print("🏊 Extracting matches from open display...")
        matches_data = []
        
        # Try different selectors for match containers in pool play
        possible_selectors = [
            '.match-card',
            '.pool-match',
            '.game-card', 
            '[class*="match"]',
            '.match-container',
            '.pool-game',
            'div[data-match]',
            '.bracket-match',  # Sometimes pools use bracket styling
            'div.div-match-card'
        ]
        
        match_containers = []
        successful_selector = None
        
        for selector in possible_selectors:
            try:
                print(f"🔍 Trying selector: {selector}")
                elements = await self.page.locator(selector).all()
                
                if elements:
                    # Filter for visible elements with content
                    visible_elements = []
                    for i, element in enumerate(elements):
                        try:
                            if await element.is_visible():
                                text = await element.text_content() or ""
                                if len(text.strip()) > 10:  # Has meaningful content
                                    visible_elements.append(element)
                                    print(f"   ✅ Found match {i + 1}: {text[:100]}...")
                        except Exception:
                            continue
                    
                    if visible_elements:
                        match_containers = visible_elements
                        successful_selector = selector
                        break
                        
            except Exception as e:
                print(f"   ❌ Selector {selector} failed: {e}")
                continue
        
        if not match_containers:
            print("❌ No match containers found, trying alternative approach...")
            return await self.extract_matches_alternative_approach(match_type, type_detail)
        
        print(f"✅ Found {len(match_containers)} match containers with selector: {successful_selector}")
        
        # Process each match container
        for i, container in enumerate(match_containers):
            try:
                print(f"🎯 Processing match {i + 1}/{len(match_containers)}...")
                
                match_data = await self.extract_match_data_from_container(container, i, match_type, type_detail)
                if match_data:
                    matches_data.append(match_data)
                    print(f"✅ Match {i + 1} extracted successfully")
                else:
                    print(f"⚠️ Match {i + 1} - no data extracted")
                    
            except Exception as e:
                print(f"❌ Error processing match {i + 1}: {e}")
                continue
        
        return matches_data
    
    async def extract_match_data_from_container(self, container, index: int, match_type: str, type_detail: str) -> Optional[Dict]:
        """
        Extract match data from a single container (pool matches are open, no clicking needed)
        """
        try:
            # Get all text content from the container
            full_text = await container.text_content() or ""
            
            print(f"🔍 Container text: {full_text[:200]}...")
            
            # Extract team names - look for various patterns
            team_names = await self.extract_team_names_from_text(full_text)
            
            # Extract time if present
            time_display = self.extract_time_from_text(full_text)
            print(f"   ⏰ Extracted time: {time_display}")
            
            # Extract court if present  
            court_display = self.extract_court_from_text(full_text)
            
            # Extract match number if present
            match_number = self.extract_match_number_from_text(full_text)
            
            # Look for VMIX button and extract API URL
            api_url = await self.extract_api_url_from_container(container)
            
            # Build match data
            match_data = {
                'index': index,
                'match_number': match_number,
                'time': time_display,
                'court': court_display,
                'team_names': team_names,
                'team1': team_names[0] if len(team_names) > 0 else None,
                'team2': team_names[1] if len(team_names) > 1 else None,
                'header_info': full_text.strip()[:100],  # First 100 chars as header info
                'match_type': match_type,
                'type_detail': type_detail
            }
            
            if api_url:
                match_data['api_url'] = api_url
            
            return match_data
            
        except Exception as e:
            print(f"❌ Error extracting match data: {e}")
            return None
    
    async def extract_team_names_from_text(self, text: str) -> List[str]:
        """
        Extract team names from match text, avoiding referee names
        """
        print(f"🔍 Extracting team names from: {text[:200]}")
        
        # Pool play specific patterns - numbers often precede team names
        pool_patterns = [
            # Pattern: "1 Team A / Player A  2 Team B / Player B" (numbers before teams)
            r'(\d+)\s+([A-Za-z\s]+/[A-Za-z\s]+)\s+(\d+)\s+([A-Za-z\s]+/[A-Za-z\s]+)',
            # Pattern: "Team A / Player A  Team B / Player B" (sequential teams)
            r'([A-Za-z\s]+/[A-Za-z\s]+)\s+([A-Za-z\s]+/[A-Za-z\s]+)(?:\s+Ref:|$)',
            # Pattern with VS: "Team A vs Team B"
            r'(.+?)\s+vs?\s+(.+?)(?:\s*[-—]\s*Court|\s*[-—]\s*Time|\s*[-—]\s*Match|\s*$)',
        ]
        
        for pattern in pool_patterns:
            match = re.search(pattern, text, re.IGNORECASE)
            if match:
                if len(match.groups()) >= 4:  # Number + team pattern
                    team1 = match.group(2).strip()
                    team2 = match.group(4).strip()
                elif len(match.groups()) >= 2:  # Direct team pattern
                    team1 = match.group(1).strip()
                    team2 = match.group(2).strip()
                else:
                    continue
                
                print(f"   Found potential teams: '{team1}' vs '{team2}'")
                
                # Filter out referee indicators and clean names
                if not self.is_likely_referee(team1) and not self.is_likely_referee(team2):
                    team1_clean = self.clean_team_name(team1)
                    team2_clean = self.clean_team_name(team2)
                    
                    if team1_clean and team2_clean and len(team1_clean) > 3 and len(team2_clean) > 3:
                        print(f"   ✅ Extracted teams: '{team1_clean}' vs '{team2_clean}'")
                        return [team1_clean, team2_clean]
        
        print("   ❌ No team names found with pool patterns")
        return []
    
    def is_likely_referee(self, text: str) -> bool:
        """Check if text is likely a referee name"""
        ref_indicators = ['ref:', 'referee', 'official', 'umpire', 'score', 'court']
        text_lower = text.lower()
        return any(indicator in text_lower for indicator in ref_indicators)
    
    def clean_team_name(self, name: str) -> str:
        """Clean up team name by removing extra whitespace and common prefixes/suffixes"""
        # Remove common prefixes
        prefixes_to_remove = ['team ', 'match ', 'game ']
        suffixes_to_remove = [' ref:', ' ref', ' referee', ' official']
        
        name_lower = name.lower()
        
        # Remove prefixes
        for prefix in prefixes_to_remove:
            if name_lower.startswith(prefix):
                name = name[len(prefix):]
                name_lower = name.lower()
        
        # Remove suffixes
        for suffix in suffixes_to_remove:
            if name_lower.endswith(suffix):
                name = name[:len(name)-len(suffix)]
                name_lower = name.lower()
        
        # Clean whitespace
        return ' '.join(name.split()).strip()
    
    def extract_time_from_text(self, text: str) -> Optional[str]:
        """Extract time from match text and fix corrupted times"""
        time_patterns = [
            r'(\d{1,2}:\d{2}\s*[AP]M)',  # 10:30AM, 2:15PM
            r'(\d{1,2}[AP]M)',           # 10AM, 2PM
            r'(\d{1,2}:\d{2})'           # 10:30, 14:15
        ]
        
        for pattern in time_patterns:
            match = re.search(pattern, text, re.IGNORECASE)
            if match:
                time_str = match.group(1)
                # Fix corrupted times like "18:00AM" -> "8:00AM"
                if ':' in time_str:
                    try:
                        time_part = time_str.replace('AM', '').replace('PM', '').replace('am', '').replace('pm', '').strip()
                        hour, minute = time_part.split(':')
                        hour_int = int(hour)
                        minute_int = int(minute)
                        
                        # Fix corrupted hours (like 18, 28, 38 should be 8, 8, 8)
                        am_pm = 'AM' if 'AM' in time_str.upper() else 'PM'
                        print(f"   🔍 Time debugging: hour={hour_int}, minute={minute_int}, am_pm={am_pm}")
                        
                        if hour_int > 12:
                            # Extract last digit for hour
                            corrected_hour = hour_int % 10
                            if corrected_hour == 0:
                                corrected_hour = 12 if am_pm == 'PM' else 10
                            corrected_time = f"{corrected_hour}:{minute:02d}{am_pm}"
                            print(f"   🔧 Fixed time from '{time_str}' to '{corrected_time}'")
                            return corrected_time
                        else:
                            print(f"   ✅ Time looks normal: {time_str}")
                            return time_str
                    except (ValueError, IndexError):
                        return time_str
                else:
                    return time_str
        
        return None
    
    def extract_court_from_text(self, text: str) -> Optional[str]:
        """Extract court from match text"""
        court_patterns = [
            r'Court\s*[:#]?\s*(\d+)',
            r'Ct\s*[:#]?\s*(\d+)',
            r'Court\s+([A-Za-z0-9]+)'
        ]
        
        for pattern in court_patterns:
            match = re.search(pattern, text, re.IGNORECASE)
            if match:
                return match.group(1)
        
        return None
    
    def extract_match_number_from_text(self, text: str) -> Optional[str]:
        """Extract match number from text"""
        match_patterns = [
            r'Match\s*[:#]?\s*(\d+)',
            r'Game\s*[:#]?\s*(\d+)',
            r'#(\d+)'
        ]
        
        for pattern in match_patterns:
            match = re.search(pattern, text, re.IGNORECASE)
            if match:
                return match.group(1)
        
        return None
    
    async def extract_api_url_from_container(self, container) -> Optional[str]:
        """
        Look for VMIX button within the container and extract API URL
        """
        try:
            # Look for VMIX button within this container
            vmix_selectors = [
                'button:has-text("VMIX")',
                'a:has-text("VMIX")', 
                '[class*="vmix"]',
                'button:has-text("V-Mix")',
                '.btn:has-text("VMIX")'
            ]
            
            for selector in vmix_selectors:
                try:
                    vmix_elements = await container.locator(selector).all()
                    for vmix_element in vmix_elements:
                        if await vmix_element.is_visible():
                            # Try to get href or onclick attribute
                            href = await vmix_element.get_attribute('href')
                            onclick = await vmix_element.get_attribute('onclick')
                            
                            if href and 'vmix' in href.lower():
                                return href
                            elif onclick and 'vmix' in onclick.lower():
                                # Extract URL from onclick
                                url_match = re.search(r'(https?://[^\'"]+)', onclick)
                                if url_match:
                                    return url_match.group(1)
                                    
                except Exception:
                    continue
            
            # If no VMIX button found, generate API URL from match ID if possible
            # Look for data attributes that might contain match ID
            match_id_attrs = ['data-match-id', 'data-id', 'data-match']
            for attr in match_id_attrs:
                try:
                    match_id = await container.get_attribute(attr)
                    if match_id:
                        return f"https://api.volleyballlife.com/api/v1.0/matches/{match_id}/vmix?bracket=false"
                except Exception:
                    continue
                    
        except Exception as e:
            print(f"⚠️ Error extracting API URL: {e}")
        
        return None
    
    async def extract_matches_alternative_approach(self, match_type: str, type_detail: str) -> List[Dict]:
        """
        Alternative approach when standard selectors don't work
        """
        print("🔄 Using alternative extraction approach...")
        
        try:
            # Get all text content and try to parse it
            page_content = await self.page.content()
            
            # Look for any elements that might contain match data
            all_elements = await self.page.locator('div, span, p').all()
            
            matches_data = []
            for i, element in enumerate(all_elements):
                try:
                    if await element.is_visible():
                        text = await element.text_content() or ""
                        if 'vs' in text.lower() and len(text.strip()) > 20:
                            # This might be a match
                            team_names = await self.extract_team_names_from_text(text)
                            if len(team_names) >= 2:
                                match_data = {
                                    'index': len(matches_data),
                                    'match_number': None,
                                    'time': self.extract_time_from_text(text),
                                    'court': self.extract_court_from_text(text),
                                    'team_names': team_names,
                                    'team1': team_names[0],
                                    'team2': team_names[1],
                                    'header_info': text[:100],
                                    'match_type': match_type,
                                    'type_detail': type_detail
                                }
                                
                                # Try to find API URL
                                api_url = await self.extract_api_url_from_container(element)
                                if api_url:
                                    match_data['api_url'] = api_url
                                
                                matches_data.append(match_data)
                                
                except Exception:
                    continue
            
            return matches_data
            
        except Exception as e:
            print(f"❌ Alternative approach failed: {e}")
            return []


async def main():
    """Main execution function for pool play scanning"""
    if len(sys.argv) < 2:
        print("Usage: python3 vbl_pool_scraper.py <pool_url> [username] [password]")
        print("Example: python3 vbl_pool_scraper.py 'https://volleyballlife.com/event/123/pools/456' user@email.com password")
        sys.exit(1)
    
    pool_url = sys.argv[1]
    username = sys.argv[2] if len(sys.argv) > 2 else None
    password = sys.argv[3] if len(sys.argv) > 3 else None
    
    # Use hardcoded credentials if not provided
    if not username:
        username = "NathanHicks25@gmail.com"
        password = "Hhklja99"
        print("🔑 Using provided credentials")
    
    print(f"🏊 VolleyballLife Pool Play Scraper")
    print(f"🌐 Target URL: {pool_url}")
    print(f"👤 Username: {username}")
    
    async with VBLPoolScraper(headless=True, timeout=20000) as scraper:
        # Execute pool extraction
        result = await scraper.extract_pool_matches(pool_url, username, password)
        
        # Save results
        output_file = Path("complete_workflow_results.json")
        with open(output_file, 'w') as f:
            json.dump(result, f, indent=2)
        print(f"\n💾 Results saved to {output_file}")
        
        # Print summary
        if result['status'] == 'success':
            print(f"\n🎉 Pool extraction successful!")
            print(f"   📊 Found {result['total_matches']} matches")
            print(f"   🏊 Type: {result.get('match_type', 'Unknown')} - {result.get('type_detail', '')}")
            
            # Show sample matches
            for i, match in enumerate(result['matches'][:3]):
                team1 = match.get('team1', '?')
                team2 = match.get('team2', '?') 
                court = match.get('court', '?')
                time = match.get('time', '?')
                api_url = '✅' if match.get('api_url') else '❌'
                
                print(f"   🏐 Match {i+1}: {team1} vs {team2}")
                print(f"      📍 Court: {court}, ⏰ Time: {time}, 🔗 API: {api_url}")
                
        else:
            print(f"💥 Pool extraction failed: {result.get('error', 'Unknown error')}")


if __name__ == "__main__":
    asyncio.run(main())