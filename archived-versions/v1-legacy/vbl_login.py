#!/usr/bin/env python3
"""
Volleyball Life Auto Login Script
Uses Playwright with WebKit to automatically log into volleyballlife.com
"""

import asyncio
import random
import sys
import json
from pathlib import Path
from playwright.async_api import async_playwright, TimeoutError as PlaywrightTimeoutError

# Configuration
EMAIL = "NathanHicks25@gmail.com"
PASSWORD = "Hhklja99"
BASE_URL = "https://volleyballlife.com"

class VBLLoginBot:
    def __init__(self):
        self.browser = None
        self.page = None
        self.context = None
        
    async def random_delay(self, min_seconds=5, max_seconds=10):
        """Add random delay between actions"""
        delay = random.uniform(min_seconds, max_seconds)
        print(f"⏱️  Waiting {delay:.1f} seconds...")
        await asyncio.sleep(delay)
    
    async def start_browser(self, headless=False):
        """Start the browser and create a new page"""
        print("🚀 Starting WebKit browser...")
        self.playwright = await async_playwright().start()
        
        # Launch WebKit browser
        self.browser = await self.playwright.webkit.launch(
            headless=headless,
            args=['--disable-web-security', '--disable-features=VizDisplayCompositor']
        )
        
        # Create browser context with realistic settings
        self.context = await self.browser.new_context(
            user_agent='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15',
            viewport={'width': 1280, 'height': 800}
        )
        
        # Create new page
        self.page = await self.context.new_page()
        
        # Set longer timeout for elements
        self.page.set_default_timeout(30000)
        
        print("✅ Browser started successfully")
    
    async def check_login_status(self):
        """Check if already logged in"""
        print("🔍 Checking if already logged in...")
        
        try:
            # Look for Sign In button (means not logged in)
            sign_in_button = await self.page.query_selector('button:has-text("Sign In")')
            if sign_in_button:
                print("❌ Not logged in - Sign In button found")
                return False
            
            # Look for user dropdown or profile element (means logged in)
            # Based on screenshots, when logged in the "Sign In" text disappears
            # and shows user profile/dropdown instead
            user_elements = await self.page.query_selector_all('[class*="user"], [class*="profile"], [class*="dropdown"]')
            
            # Also check if the text "Sign In" is not visible in the top right
            top_right = await self.page.query_selector('[class*="toolbar"] [class*="content"]')
            if top_right:
                text_content = await top_right.text_content()
                if "Sign In" not in text_content:
                    print("✅ Already logged in - Sign In not found in toolbar")
                    return True
            
            print("❓ Login status unclear - proceeding with login")
            return False
            
        except Exception as e:
            print(f"⚠️  Error checking login status: {e}")
            return False
    
    async def login(self):
        """Perform the login process"""
        try:
            # Navigate to the site
            print(f"🌐 Navigating to {BASE_URL}...")
            await self.page.goto(BASE_URL, wait_until='networkidle')
            
            await self.random_delay()
            
            # Check if already logged in
            if await self.check_login_status():
                print("🎉 Already logged in!")
                return True
            
            print("🔐 Starting login process...")
            
            # Step 1: Click the Sign In button
            print("👆 Clicking Sign In button...")
            
            # Try multiple selectors for the sign in button
            sign_in_selectors = [
                'button:has-text("Sign In")',
                '[class*="btn"]:has-text("Sign In")',
                'button[class*="btn"]:has-text("Sign In")',
                '.v-btn:has-text("Sign In")'
            ]
            
            sign_in_clicked = False
            for selector in sign_in_selectors:
                try:
                    sign_in_button = await self.page.wait_for_selector(selector, timeout=5000)
                    if sign_in_button:
                        await sign_in_button.click()
                        sign_in_clicked = True
                        print("✅ Sign In button clicked")
                        break
                except:
                    continue
            
            if not sign_in_clicked:
                raise Exception("Could not find or click Sign In button")
            
            await self.random_delay()
            
            # Step 2: Wait for login modal and enter email
            print("📧 Entering email address...")
            
            # Wait for the email input field in the modal
            email_selectors = [
                'input[type="text"][placeholder*="Email" i]',
                'input[placeholder*="Email" i]', 
                'input[type="email"]',
                'input[aria-describedby*="input-v-12-2" i]',
                'input[id*="input-v-12"]',
                '.v-field__input input',
                'div[role="dialog"] input',
                'div[class*="window"] input[type="text"]'
            ]
            
            email_input = None
            for selector in email_selectors:
                try:
                    email_input = await self.page.wait_for_selector(selector, timeout=5000)
                    if email_input:
                        break
                except:
                    continue
            
            if not email_input:
                # Debug: Print available input elements
                print("🐛 Debugging - looking for input elements...")
                inputs = await self.page.query_selector_all('input')
                for i, inp in enumerate(inputs):
                    try:
                        tag = await inp.get_attribute('type') or 'text'
                        placeholder = await inp.get_attribute('placeholder') or ''
                        id_attr = await inp.get_attribute('id') or ''
                        classes = await inp.get_attribute('class') or ''
                        print(f"   Input {i+1}: type='{tag}' placeholder='{placeholder}' id='{id_attr}' class='{classes[:50]}...'")
                    except:
                        pass
                
                raise Exception("Could not find email input field")
            
            # Clear and type email
            await email_input.click()
            await email_input.fill("")  # Clear field
            await email_input.type(EMAIL, delay=100)
            print(f"✅ Email entered: {EMAIL}")
            
            await self.random_delay()
            
            # Step 3: Click Continue button
            print("👆 Clicking Continue button...")
            
            continue_selectors = [
                'button:has-text("Continue")',
                '[class*="btn"]:has-text("Continue")',
                'button[class*="btn"]:has-text("Continue")'
            ]
            
            continue_clicked = False
            for selector in continue_selectors:
                try:
                    continue_button = await self.page.wait_for_selector(selector, timeout=5000)
                    if continue_button:
                        await continue_button.click()
                        continue_clicked = True
                        print("✅ Continue button clicked")
                        break
                except:
                    continue
            
            if not continue_clicked:
                raise Exception("Could not find or click Continue button")
            
            await self.random_delay()
            
            # Step 4: Wait for password field and enter password
            print("🔑 Entering password...")
            
            # Wait for password field to appear
            password_selectors = [
                'input[type="password"]',
                'input[placeholder*="password" i]',
                'input[placeholder*="Password" i]',
                '#input-v-12-11',  # Based on screenshot pattern
                'input[class*="v-field__input"][type="password"]'
            ]
            
            password_input = None
            for selector in password_selectors:
                try:
                    password_input = await self.page.wait_for_selector(selector, timeout=10000)
                    if password_input:
                        break
                except:
                    continue
            
            if not password_input:
                raise Exception("Could not find password input field")
            
            # Clear and type password
            await password_input.click()
            await password_input.fill("")  # Clear field
            await password_input.type(PASSWORD, delay=100)
            print("✅ Password entered")
            
            await self.random_delay()
            
            # Step 5: Click Sign In button (final submit)
            print("👆 Clicking final Sign In button...")
            
            final_signin_selectors = [
                'button:has-text("Sign In")',
                '[class*="btn"]:has-text("Sign In")',
                'button[type="submit"]',
                'button[class*="btn"][class*="accent"]'
            ]
            
            signin_clicked = False
            for selector in final_signin_selectors:
                try:
                    signin_button = await self.page.wait_for_selector(selector, timeout=5000)
                    if signin_button:
                        await signin_button.click()
                        signin_clicked = True
                        print("✅ Final Sign In button clicked")
                        break
                except:
                    continue
            
            if not signin_clicked:
                raise Exception("Could not find or click final Sign In button")
            
            # Step 6: Wait for login to complete
            print("⏳ Waiting for login to complete...")
            await asyncio.sleep(3)
            
            # Check if login was successful
            try:
                # Wait for modal to disappear or page to change
                await self.page.wait_for_function(
                    "() => !document.querySelector('div:has-text(\"Sign In or Sign Up\")')",
                    timeout=10000
                )
                
                # Verify login success
                if await self.check_login_status():
                    print("🎉 Login successful!")
                    return True
                else:
                    print("❌ Login may have failed - still seeing Sign In button")
                    return False
                    
            except PlaywrightTimeoutError:
                print("⚠️  Login timeout - checking status...")
                return await self.check_login_status()
        
        except Exception as e:
            print(f"❌ Login error: {e}")
            return False
    
    async def close(self):
        """Clean up browser resources"""
        if self.browser:
            await self.browser.close()
        if self.playwright:
            await self.playwright.stop()

async def main():
    """Main function"""
    bot = VBLLoginBot()
    
    try:
        # Start browser (headless=False to show window)
        await bot.start_browser(headless=False)
        
        # Perform login
        success = await bot.login()
        
        if success:
            print("✅ Login completed successfully!")
            # Keep browser open for a bit to see the result
            print("🖥️  Keeping browser open for 10 seconds...")
            await asyncio.sleep(10)
            return 0
        else:
            print("❌ Login failed!")
            # Keep browser open for debugging
            print("🖥️  Keeping browser open for 10 seconds for debugging...")
            await asyncio.sleep(10)
            return 1
            
    except Exception as e:
        print(f"💥 Unexpected error: {e}")
        return 1
        
    finally:
        await bot.close()

if __name__ == "__main__":
    # Run the async main function
    exit_code = asyncio.run(main())
    sys.exit(exit_code)