#!/usr/bin/env python3
"""
VolleyballLife Complete Login System
Follows the exact four-phase login workflow from screenshot analysis
"""

import asyncio
import json
import sys
from datetime import datetime
from pathlib import Path
from typing import Optional

from vbl_precise_scraper import VBLPreciseScraper


class VBLCompleteLogin(VBLPreciseScraper):
    """Complete login system following four-phase workflow"""
    
    def determine_url_type(self, url: str):
        """
        Determine match type and additional info from URL
        Returns: (match_type, additional_info)
        """
        url_lower = url.lower()
        
        if '/pools/' in url_lower:
            # Extract pool number from URL if possible
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
    
    async def complete_login_and_scan(self, bracket_url: str, username: str = None, password: str = None) -> dict:
        """
        Complete workflow: Login check -> Login if needed -> Scan bracket
        """
        try:
            print(f"🎯 Starting complete VBL workflow")
            print(f"📍 Target bracket: {bracket_url}")
            print(f"🔐 Credentials: {'Provided' if username and password else 'Missing'}")
            
            # Determine match type from URL
            match_type, type_detail = self.determine_url_type(bracket_url)
            print(f"📋 Detected: {match_type} - {type_detail}")
            
            # Always start with initial setup and V3 switching
            await self.phase_1_initial_setup()
            
            # Check current login status using session
            login_needed = not await self.check_login_status()
            
            if login_needed and username and password:
                print("🔐 Login required - starting login process...")
                login_success = await self.four_phase_login(username, password)
                
                if not login_success:
                    print("❌ Login failed - proceeding without authentication")
            elif login_needed:
                print("⚠️ Login required but no credentials provided")
            else:
                print("✅ Already logged in or login not required")
            
            # Now proceed with bracket scanning
            print(f"\n🎯 Starting bracket scan...")
            await self.page.goto(bracket_url)
            await self.page.wait_for_load_state('networkidle')
            
            # Wait 4.2 seconds before interacting with bracket to ensure page is fully loaded
            print("⏳ Waiting 4.2 seconds for bracket page to fully load...")
            await asyncio.sleep(4.2)
            print("✅ Page load delay complete - proceeding with bracket scanning")
            
            # Execute three-phase bracket scanning
            matches_data = await self.execute_three_phases()
            
            # Add match type information to each match
            for match in matches_data:
                match['match_type'] = match_type
                match['type_detail'] = type_detail
            
            result = {
                'url': bracket_url,
                'timestamp': datetime.now().isoformat(),
                'total_matches': len(matches_data),
                'matches': matches_data,
                'match_type': match_type,
                'type_detail': type_detail,
                'login_performed': login_needed and username and password,
                'status': 'success' if matches_data else 'no_matches'
            }
            
            print(f"✅ Complete workflow finished - extracted {len(matches_data)} matches")
            return result
            
        except Exception as e:
            print(f"❌ Error in complete workflow: {e}")
            return {
                'url': bracket_url,
                'timestamp': datetime.now().isoformat(),
                'error': str(e),
                'status': 'error'
            }
    
    async def phase_1_initial_setup(self):
        """
        Phase 1: Initial Page Setup and View Switching
        1. Navigate to volleyballlife.com
        2. Check for "Switch to V3 View" button and click if present
        3. Wait for navigation to complete
        """
        print("\n🏆 PHASE 1: Initial Page Setup and View Switching")
        
        # Step 1: Navigate to the initial URL
        print("📍 Step 1: Navigating to https://volleyballlife.com...")
        await self.page.goto('https://volleyballlife.com')
        await self.page.wait_for_load_state('networkidle')
        
        # Step 2: Check for "Switch to V3 View" button
        print("🔍 Step 2: Checking for 'Switch to V3 View' button...")
        
        try:
            # Use if await page.is_visible(selector) block
            v3_button_selector = 'button:has-text("SWITCH TO V3 VIEW")'
            
            if await self.page.is_visible(v3_button_selector):
                print("✅ Found V3 switch button - clicking...")
                await self.page.click(v3_button_selector)
                
                # Step 3: Wait for navigation after clicking
                print("⏳ Step 3: Waiting for navigation to complete...")
                await self.page.wait_for_load_state('networkidle')
                await asyncio.sleep(1.2)  # Extra wait for page to fully load
                
                print("✅ Successfully switched to V3 view")
            else:
                print("✅ Already in V3 view (no switch button found)")
                
        except Exception as e:
            print(f"⚠️ V3 switch check failed (likely already in V3): {e}")
        
        print("✅ Phase 1 complete - Initial setup finished")
    
    async def check_login_required(self) -> bool:
        """Check if login is required by looking for sign-in indicators"""
        try:
            # Look for "Sign In" button in header - indicates not logged in
            sign_in_selectors = [
                'button:has-text("Sign In")',
                'a:has-text("Sign In")',
                '[class*="sign-in"]'
            ]
            
            for selector in sign_in_selectors:
                try:
                    if await self.page.is_visible(selector):
                        print(f"🔍 Found sign-in indicator: {selector}")
                        return True
                except Exception:
                    continue
            
            # Look for user profile indicators - suggests logged in
            profile_selectors = [
                '[class*="profile"]',
                '[class*="avatar"]',
                'button:has-text("Logout")',
                'a:has-text("Profile")'
            ]
            
            for selector in profile_selectors:
                try:
                    if await self.page.is_visible(selector):
                        print(f"✅ Found profile indicator - already logged in: {selector}")
                        return False
                except Exception:
                    continue
            
            # Default: assume login is needed if we can't determine
            print("❓ Cannot determine login status - assuming login needed")
            return True
            
        except Exception as e:
            print(f"⚠️ Error checking login status: {e}")
            return True
    
    async def four_phase_login(self, username: str, password: str) -> bool:
        """
        Execute the four-phase login process
        """
        try:
            print("\n🏆 Starting Four-Phase Login Process")
            
            # Phase 2: Opening the Sign-In Modal
            if not await self.phase_2_open_signin_modal():
                return False
                
            # Phase 3: Entering Credentials  
            if not await self.phase_3_enter_credentials(username, password):
                return False
                
            # Phase 4: Confirming Successful Login
            if not await self.phase_4_confirm_login():
                return False
                
            print("🎉 Four-phase login completed successfully!")
            return True
            
        except Exception as e:
            print(f"❌ Four-phase login failed: {e}")
            return False
    
    async def phase_2_open_signin_modal(self) -> bool:
        """
        Phase 2: Opening the Sign-In Modal
        1. Find and click the main "Sign In" button
        2. Wait for the modal to appear
        """
        print("\n🏆 PHASE 2: Opening the Sign-In Modal")
        
        try:
            # Step 1: Find and click the main "Sign In" button
            print("🔍 Step 1: Finding main 'Sign In' button...")
            sign_in_selector = 'button:has-text("Sign In")'
            
            await self.page.wait_for_selector(sign_in_selector, timeout=10000)
            await self.page.click(sign_in_selector)
            print("✅ Clicked main 'Sign In' button")
            
            # Step 2: Wait for the modal to appear
            print("⏳ Step 2: Waiting for sign-in modal...")
            modal_selector = 'div.v-card-title:has-text("Sign In or Sign Up")'
            
            await self.page.wait_for_selector(modal_selector, timeout=10000)
            print("✅ Sign-in modal appeared")
            
            return True
            
        except Exception as e:
            print(f"❌ Phase 2 failed: {e}")
            return False
    
    async def phase_3_enter_credentials(self, username: str, password: str) -> bool:
        """
        Phase 3: Entering Credentials
        Two-step process: email -> continue -> password -> sign in
        """
        print("\n🏆 PHASE 3: Entering Credentials")
        
        try:
            # Step 1: Enter Email
            print("📧 Step 1: Entering email...")
            # Try multiple selectors for the email field within the modal
            email_selectors = [
                'div.v-card input[type="text"]',  # Email field within the modal
                'input[aria-label="Email"]',
                'input[placeholder*="email"]',
                'div[class*="modal"] input[type="text"]',
                'div[class*="dialog"] input[type="text"]'
            ]
            
            email_field = None
            for selector in email_selectors:
                try:
                    elements = await self.page.locator(selector).all()
                    for element in elements:
                        # Check if this element is within the modal and visible
                        if await element.is_visible() and await element.is_enabled():
                            # Additional check: make sure it's not the search box
                            placeholder = await element.get_attribute('placeholder') or ""
                            if 'search' not in placeholder.lower():
                                email_field = element
                                print(f"✅ Found email field with selector: {selector}")
                                break
                    if email_field:
                        break
                except Exception:
                    continue
            
            if not email_field:
                print("❌ Could not find email input field")
                return False
            
            await email_field.fill(username)
            print(f"✅ Entered email: {username}")
            
            # Step 2: Click Continue
            print("👆 Step 2: Clicking 'Continue' button...")
            continue_selector = 'button:has-text("Continue")'
            
            await self.page.click(continue_selector)
            print("✅ Clicked 'Continue'")
            
            # Step 3: Wait for Password Field
            print("⏳ Step 3: Waiting for password field...")
            password_selector = 'input[type="password"]'
            
            await self.page.wait_for_selector(password_selector, timeout=10000)
            print("✅ Password field appeared")
            
            # Step 4: Enter Password
            print("🔒 Step 4: Entering password...")
            await self.page.fill(password_selector, password)
            print("✅ Password entered")
            
            # Small delay to let the form process the password input
            await asyncio.sleep(0.6)
            
            # Step 5: Click Final "Sign In" Button
            print("👆 Step 5: Clicking final 'Sign In' button...")
            
            # Try multiple approaches to find and click the sign-in button
            final_signin_selectors = [
                'div.v-card button:has-text("Sign In")',  # Within the modal card
                'button[type="submit"]:has-text("Sign In")',  # Submit button variant
                'button:has-text("Sign In"):not(:disabled)',  # Enabled sign-in button
                'form button:has-text("Sign In")',  # Within a form
                'button:has-text("Sign In")'  # Fallback
            ]
            
            sign_in_clicked = False
            for selector in final_signin_selectors:
                try:
                    print(f"🔍 Trying selector: {selector}")
                    # Wait for the button to be available and enabled
                    await self.page.wait_for_selector(selector, timeout=5000)
                    
                    # Check if button is visible and enabled
                    button = self.page.locator(selector).first
                    if await button.is_visible() and await button.is_enabled():
                        await button.click()
                        print(f"✅ Clicked final 'Sign In' button with selector: {selector}")
                        sign_in_clicked = True
                        break
                except Exception as e:
                    print(f"⚠️ Selector {selector} failed: {e}")
                    continue
            
            if not sign_in_clicked:
                # Try pressing Enter as a fallback
                print("🔄 Trying Enter key as fallback...")
                try:
                    await self.page.keyboard.press('Enter')
                    print("✅ Pressed Enter key")
                    sign_in_clicked = True
                except Exception as e:
                    print(f"❌ Enter key failed: {e}")
            
            if not sign_in_clicked:
                print("❌ Failed to click final sign-in button")
                return False
            
            return True
            
        except Exception as e:
            print(f"❌ Phase 3 failed: {e}")
            return False
    
    async def phase_4_confirm_login(self) -> bool:
        """
        Phase 4: Confirming Successful Login
        Wait for the main "Sign In" button to disappear or change
        """
        print("\n🏆 PHASE 4: Confirming Successful Login")
        
        try:
            print("⏳ Waiting for login confirmation...")
            
            # Wait for the main "Sign In" button to disappear (indicating successful login)
            sign_in_button_selector = 'button:has-text("Sign In")'
            
            await self.page.wait_for_selector(sign_in_button_selector, state='hidden', timeout=15000)
            print("✅ Main 'Sign In' button disappeared - login successful!")
            
            # Additional confirmation: wait for page to fully update
            await asyncio.sleep(1.2)
            
            # Save the session for future use
            await self.save_session()
            
            return True
            
        except Exception as e:
            print(f"❌ Phase 4 failed - login may not have succeeded: {e}")
            
            # Try alternative confirmation method
            try:
                print("🔄 Trying alternative confirmation method...")
                
                # Look for profile/user indicators
                profile_indicators = [
                    '[class*="profile"]',
                    '[class*="avatar"]',
                    '[class*="user"]',
                    'button:has-text("Logout")'
                ]
                
                for selector in profile_indicators:
                    try:
                        if await self.page.is_visible(selector):
                            print(f"✅ Found profile indicator - login confirmed: {selector}")
                            await self.save_session()
                            return True
                    except Exception:
                        continue
                        
                print("❌ Could not confirm login success")
                return False
                
            except Exception:
                return False


async def main():
    """Main execution function"""
    if len(sys.argv) < 2:
        print("Usage: python3 vbl_complete_login.py <bracket_url> [username] [password]")
        print("Example: python3 vbl_complete_login.py 'https://volleyballlife.com/event/123/brackets' user@email.com password")
        sys.exit(1)
    
    bracket_url = sys.argv[1]
    username = sys.argv[2] if len(sys.argv) > 2 else None
    password = sys.argv[3] if len(sys.argv) > 3 else None
    
    # Use hardcoded credentials if not provided
    if not username:
        username = "NathanHicks25@gmail.com"
        password = "Hhklja99"
        print("🔑 Using provided credentials")
    
    print(f"🎯 VolleyballLife Complete Login & Scan System")
    print(f"🌐 Target URL: {bracket_url}")
    print(f"👤 Username: {username}")
    print(f"📋 Following four-phase login plan")
    
    async with VBLCompleteLogin(headless=True, timeout=20000) as scraper:
        # Execute complete workflow
        result = await scraper.complete_login_and_scan(bracket_url, username, password)
        
        # Save results
        output_file = Path("complete_workflow_results.json")
        with open(output_file, 'w') as f:
            json.dump(result, f, indent=2)
        print(f"\n💾 Results saved to {output_file}")
        
        # Print summary
        if result['status'] == 'success':
            print(f"\n🎉 Complete workflow successful!")
            print(f"   📊 Found {result['total_matches']} matches")
            print(f"   🔐 Login performed: {result.get('login_performed', False)}")
            
            # Show sample matches
            for i, match in enumerate(result['matches'][:2]):
                team1 = match.get('team1', '?')
                team2 = match.get('team2', '?') 
                court = match.get('court', '?')
                time = match.get('time', '?')
                api_url = '✅' if match.get('api_url') else '❌'
                
                print(f"   🏐 Match {i+1}: {team1} vs {team2}")
                print(f"      📍 Court: {court}, ⏰ Time: {time}, 🔗 API: {api_url}")
                
        else:
            print(f"💥 Workflow failed: {result.get('error', 'Unknown error')}")


if __name__ == "__main__":
    asyncio.run(main())