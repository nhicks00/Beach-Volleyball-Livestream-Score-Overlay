#!/usr/bin/env python3
"""
VolleyballLife Login Test using Playwright
Simplified login script for testing authentication
"""

import asyncio
import json
import sys
from pathlib import Path

from vbl_playwright_scraper import VBLPlaywrightScraper


async def test_login():
    """Test login functionality"""
    
    # Check if we have saved credentials
    creds_file = Path("vbl_credentials.json")
    
    if not creds_file.exists():
        print("❌ No credentials file found!")
        print("📝 Please create vbl_credentials.json with your login info:")
        print('   {"username": "your_email", "password": "your_password"}')
        sys.exit(1)
    
    # Load credentials
    try:
        with open(creds_file, 'r') as f:
            creds = json.load(f)
        username = creds['username'] 
        password = creds['password']
    except Exception as e:
        print(f"❌ Error loading credentials: {e}")
        sys.exit(1)
    
    print("🔐 Testing VolleyballLife login with Playwright...")
    
    # Test login with visible browser (headless=False for debugging)
    async with VBLPlaywrightScraper(headless=False, timeout=15000) as scraper:
        
        # Attempt login
        login_success = await scraper.login(username, password)
        
        if login_success:
            print("✅ Login successful!")
            
            # Test if we can access a protected page
            print("🧪 Testing access to dashboard...")
            try:
                await scraper.page.goto('https://volleyballlife.com/dashboard')
                await scraper.page.wait_for_load_state('networkidle')
                
                # Check for user-specific content
                if await scraper.is_logged_in():
                    print("✅ Dashboard access confirmed - login working!")
                else:
                    print("⚠️ Dashboard access unclear")
                    
                # Keep browser open for manual inspection
                print("🔍 Browser will stay open for 10 seconds for manual inspection...")
                await asyncio.sleep(10)
                
            except Exception as e:
                print(f"⚠️ Error accessing dashboard: {e}")
        else:
            print("❌ Login failed!")
            
        return login_success


if __name__ == "__main__":
    result = asyncio.run(test_login())
    if result:
        print("🎉 Login test completed successfully!")
    else:
        print("💥 Login test failed!")
        sys.exit(1)