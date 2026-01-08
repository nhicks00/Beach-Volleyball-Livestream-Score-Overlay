#!/usr/bin/env python3
"""
Test script to check if Playwright is installed and working
"""

import sys
import subprocess
import asyncio

async def test_playwright():
    try:
        from playwright.async_api import async_playwright
        print("✅ Playwright is installed!")
        
        # Test browser launch
        print("🧪 Testing WebKit browser launch...")
        async with async_playwright() as p:
            browser = await p.webkit.launch(headless=True)
            page = await browser.new_page()
            await page.goto('https://example.com')
            title = await page.title()
            print(f"✅ Browser test successful! Page title: {title}")
            await browser.close()
            
        return True
        
    except ImportError:
        print("❌ Playwright not installed!")
        print("📦 Installing Playwright...")
        
        try:
            # Install playwright
            subprocess.run([sys.executable, "-m", "pip", "install", "playwright"], check=True)
            print("✅ Playwright installed!")
            
            # Install browser binaries
            subprocess.run([sys.executable, "-m", "playwright", "install", "webkit"], check=True)
            print("✅ WebKit browser installed!")
            
            return True
            
        except subprocess.CalledProcessError as e:
            print(f"❌ Installation failed: {e}")
            return False
            
    except Exception as e:
        print(f"❌ Error: {e}")
        return False

if __name__ == "__main__":
    result = asyncio.run(test_playwright())
    if result:
        print("🎉 All tests passed! Ready to run VBL login script.")
    else:
        print("💥 Tests failed. Please check the installation.")
        sys.exit(1)