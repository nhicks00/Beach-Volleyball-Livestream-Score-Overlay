#!/usr/bin/env python3
"""
VolleyballLife Bracket Scanner - Real Tournament Data
Extracts match data and vMix API URLs from live tournament brackets using Selenium
"""

import requests
import time
import random
import sys
import re
import json
import datetime
import os
from urllib.parse import urljoin, urlparse
from http.cookiejar import CookieJar
import urllib3

# Disable SSL warnings for development
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Try to import Selenium for JavaScript-heavy pages
try:
    from selenium import webdriver
    from selenium.webdriver.common.by import By
    from selenium.webdriver.support.ui import WebDriverWait
    from selenium.webdriver.support import expected_conditions as EC
    from selenium.webdriver.chrome.options import Options
    from selenium.webdriver.safari.options import Options as SafariOptions
    SELENIUM_AVAILABLE = True
    print("✅ Selenium available - will use browser automation for JavaScript pages")
except ImportError:
    SELENIUM_AVAILABLE = False
    print("⚠️  Selenium not available - falling back to HTTP requests only")

# Session persistence
COOKIES_FILE = "/Users/nathanhicks/Library/Containers/com.NathanHicks.MultiCourtScore/Data/Documents/vbl_session_cookies.json"

class VBLBracketScanner:
    def __init__(self):
        self.session = requests.Session()
        
        # Set a realistic user agent
        self.session.headers.update({
            'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15',
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'en-us',
            'Accept-Encoding': 'gzip, deflate',
            'Connection': 'keep-alive',
            'Upgrade-Insecure-Requests': '1'
        })
        
        # Configure SSL handling
        self.session.verify = True
        self.session.timeout = 30
        
        # Storage for extracted matches
        self.matches = []
        
        # Login credentials
        self.email = "NathanHicks25@gmail.com"
        self.password = "Hhklja99"
        self.base_url = "https://volleyballlife.com"
        
        # Load existing session if available
        self.load_session()
    
    def random_delay(self, min_seconds=2, max_seconds=5):
        """Add random delay between actions"""
        delay = random.uniform(min_seconds, max_seconds)
        print(f"⏱️  Waiting {delay:.1f} seconds...")
        time.sleep(delay)
    
    def load_session(self):
        """Load existing session cookies if available"""
        try:
            if not os.path.exists(COOKIES_FILE):
                print("🆕 No existing session found for scanner")
                return False
            
            with open(COOKIES_FILE, 'r') as f:
                cookie_dict = json.load(f)
            
            # Add cookies to session
            for name, cookie_data in cookie_dict.items():
                self.session.cookies.set(
                    name=name,
                    value=cookie_data['value'],
                    domain=cookie_data.get('domain'),
                    path=cookie_data.get('path', '/'),
                    secure=cookie_data.get('secure', False)
                )
            
            print(f"🔄 Scanner loaded session with {len(cookie_dict)} cookies")
            return True
            
        except Exception as e:
            print(f"⚠️  Scanner failed to load session: {e}")
            return False
    
    def is_session_valid(self):
        """Check if the current session is still valid"""
        try:
            print("🔍 Scanner checking if existing session is still valid...")
            response = self.session.get(self.base_url, timeout=10)
            
            if response.status_code == 200:
                is_logged_in = self.check_login_status(response.text)
                if is_logged_in:
                    print("✅ Scanner session is valid!")
                    return True
                else:
                    print("❌ Scanner session expired")
                    return False
            else:
                print(f"❌ Scanner session check failed with status {response.status_code}")
                return False
                
        except Exception as e:
            print(f"❌ Scanner session validation error: {e}")
            return False
    
    def check_login_status(self, response_text):
        """Check if already logged in by looking for specific indicators"""
        text_lower = response_text.lower()
        
        # Look for logged-in indicators
        logged_in_indicators = [
            'logout', 'sign out', 'my account', 'dashboard', 
            'profile', 'settings', 'welcome', 'hello'
        ]
        
        # Look for login required indicators
        login_required_indicators = [
            'sign in', 'login', 'log in', 'email', 'password'
        ]
        
        logged_in_score = 0
        login_required_score = 0
        
        for indicator in logged_in_indicators:
            if indicator in text_lower:
                logged_in_score += 1
        
        for indicator in login_required_indicators:
            if indicator in text_lower:
                login_required_score += 1
        
        return logged_in_score > login_required_score
    
    def extract_form_data(self, html_content):
        """Extract form data and action URL from HTML"""
        try:
            # Look for form tags
            form_pattern = r'<form[^>]*>(.*?)</form>'
            forms = re.findall(form_pattern, html_content, re.DOTALL | re.IGNORECASE)
            
            if not forms:
                return None, {}
            
            form_html = forms[0]  # Use first form
            
            # Extract action
            action_match = re.search(r'action=["\']([^"\']*)["\']', form_html, re.IGNORECASE)
            action = action_match.group(1) if action_match else ""
            
            # Extract input fields
            input_pattern = r'<input[^>]*>'
            inputs = re.findall(input_pattern, form_html, re.IGNORECASE)
            
            form_data = {}
            for input_tag in inputs:
                name_match = re.search(r'name=["\']([^"\']*)["\']', input_tag, re.IGNORECASE)
                value_match = re.search(r'value=["\']([^"\']*)["\']', input_tag, re.IGNORECASE)
                type_match = re.search(r'type=["\']([^"\']*)["\']', input_tag, re.IGNORECASE)
                
                if name_match:
                    name = name_match.group(1)
                    value = value_match.group(1) if value_match else ""
                    input_type = type_match.group(1) if type_match else "text"
                    
                    # Include hidden fields and tokens
                    if input_type.lower() in ['hidden', 'text', 'email', 'password']:
                        form_data[name] = value
            
            return action, form_data
            
        except Exception as e:
            print(f"⚠️  Error extracting form data: {e}")
            return None, {}
    
    def perform_login(self):
        """Perform login to VolleyballLife with session persistence"""
        print("🔐 Performing login to VolleyballLife...")
        
        try:
            # First, check if we have a valid existing session
            if self.session.cookies:
                print("🔄 Found existing session, validating...")
                if self.is_session_valid():
                    return True
                else:
                    print("💧 Session expired, need to re-authenticate")
            
            # Navigate to main page
            response = self.session.get(self.base_url)
            response.raise_for_status()
            
            self.random_delay(1, 2)
            
            # Check if already logged in
            if self.check_login_status(response.text):
                print("✅ Already logged in!")
                return True
            
            print("🔍 Looking for login form...")
            
            # Look for login/signin links
            signin_patterns = [
                r'href=["\']([^"\']*signin[^"\']*)["\']',
                r'href=["\']([^"\']*login[^"\']*)["\']',
                r'href=["\']([^"\']*auth[^"\']*)["\']'
            ]
            
            login_url = None
            for pattern in signin_patterns:
                matches = re.findall(pattern, response.text, re.IGNORECASE)
                if matches:
                    login_url = matches[0]
                    break
            
            if login_url:
                if not login_url.startswith('http'):
                    login_url = urljoin(self.base_url, login_url)
                print(f"🔗 Found login URL: {login_url}")
                
                self.random_delay(1, 2)
                
                # Navigate to login page
                login_response = self.session.get(login_url)
                login_response.raise_for_status()
                
                self.random_delay(1, 2)
                
                # Extract form data
                action, form_data = self.extract_form_data(login_response.text)
                
                if form_data:
                    form_url = urljoin(login_url, action) if action else login_url
                    
                    # Fill in credentials
                    form_data['email'] = self.email
                    form_data['password'] = self.password
                    
                    print("📧 Submitting login credentials...")
                    login_submit = self.session.post(form_url, data=form_data)
                    
                    self.random_delay(1, 2)
                    
                    # Check if login was successful
                    if login_submit.status_code in [200, 302]:
                        if self.check_login_status(login_submit.text):
                            print("✅ Login successful!")
                            return True
            
            print("⚠️  Could not complete login automatically")
            return False
            
        except Exception as e:
            print(f"❌ Login error: {e}")
            return False
    
    def parse_time_to_minutes(self, time_str):
        """Convert time string to minutes since midnight for sorting"""
        try:
            # Handle formats like "9:00 AM", "12:00 PM", "1:00 PM"
            time_str = time_str.replace(' ', '').upper()
            
            # Extract time and AM/PM
            if 'AM' in time_str:
                time_part = time_str.replace('AM', '')
                is_pm = False
            elif 'PM' in time_str:
                time_part = time_str.replace('PM', '')
                is_pm = True
            else:
                # Assume 24-hour format
                time_part = time_str
                is_pm = False
            
            # Parse hour and minute
            if ':' in time_part:
                hour, minute = map(int, time_part.split(':'))
            else:
                hour = int(time_part)
                minute = 0
            
            # Convert to 24-hour format
            if is_pm and hour != 12:
                hour += 12
            elif not is_pm and hour == 12:
                hour = 0
            
            # Convert to minutes since midnight
            return hour * 60 + minute
            
        except Exception as e:
            print(f"⚠️  Error parsing time '{time_str}': {e}")
            return 0
    
    def discover_api_endpoints(self, html_content, bracket_url):
        """Try to discover API endpoints from the Vue.js application"""
        print("🔍 Discovering API endpoints from Vue.js app...")
        
        # Extract URL components
        url_parts = bracket_url.split('/')
        event_id = None
        division_id = None
        round_id = None
        
        for i, part in enumerate(url_parts):
            if part == 'event' and i + 1 < len(url_parts):
                event_id = url_parts[i + 1]
            elif part == 'division' and i + 1 < len(url_parts):
                division_id = url_parts[i + 1]
            elif part == 'round' and i + 1 < len(url_parts):
                round_id = url_parts[i + 1]
        
        print(f"🔢 Extracted IDs: Event={event_id}, Division={division_id}, Round={round_id}")
        
        # Common API endpoint patterns for sports/tournament apps
        potential_endpoints = []
        
        if event_id and division_id and round_id:
            # Try various API patterns
            api_patterns = [
                f"/api/events/{event_id}/divisions/{division_id}/rounds/{round_id}/matches",
                f"/api/events/{event_id}/divisions/{division_id}/matches",
                f"/api/rounds/{round_id}/matches",
                f"/api/brackets/{event_id}/{division_id}/{round_id}",
                f"/api/v1/events/{event_id}/divisions/{division_id}/rounds/{round_id}/matches",
                f"/api/tournament/{event_id}/division/{division_id}/round/{round_id}/brackets",
                f"/api/tournament/matches?event={event_id}&division={division_id}&round={round_id}",
            ]
            
            for pattern in api_patterns:
                full_url = urljoin(self.base_url, pattern)
                potential_endpoints.append(full_url)
        
        return potential_endpoints
    
    def try_api_endpoints(self, endpoints):
        """Try discovered API endpoints to fetch match data"""
        print(f"🔗 Testing {len(endpoints)} potential API endpoints...")
        
        for i, endpoint in enumerate(endpoints, 1):
            try:
                print(f"   {i}. Testing: {endpoint}")
                
                # Add API headers that are commonly expected
                headers = {
                    'Accept': 'application/json, text/plain, */*',
                    'Content-Type': 'application/json',
                    'X-Requested-With': 'XMLHttpRequest',
                }
                
                response = self.session.get(endpoint, headers=headers)
                print(f"      Status: {response.status_code}")
                
                if response.status_code == 200:
                    try:
                        data = response.json()
                        print(f"      ✅ Got JSON data: {len(str(data))} chars")
                        
                        # Check if this looks like match data
                        if isinstance(data, (list, dict)):
                            data_str = str(data).lower()
                            if any(keyword in data_str for keyword in ['match', 'court', 'team', 'time', 'bracket']):
                                print(f"      🎯 Contains match-related data!")
                                return endpoint, data
                    
                    except ValueError:
                        # Not JSON, check if it's useful HTML/text
                        content = response.text
                        if len(content) > 1000 and any(keyword in content.lower() for keyword in ['match', 'court', 'team']):
                            print(f"      📄 Contains match-related content")
                            return endpoint, content
                
                self.random_delay(0.5, 1)  # Short delay between API attempts
                
            except Exception as e:
                print(f"      ❌ Error: {e}")
        
        return None, None
    
    def setup_selenium_driver(self):
        """Set up Selenium WebDriver for JavaScript pages"""
        print("🔧 Setting up Selenium WebDriver...")
        
        if not SELENIUM_AVAILABLE:
            print("❌ Selenium not available - cannot setup WebDriver")
            return None
        
        try:
            print("🔍 Trying Safari WebDriver first...")
            # Try Safari first (comes with macOS)
            options = SafariOptions()
            driver = webdriver.Safari(options=options)
            print("✅ Safari WebDriver successfully created")
            return driver
        except Exception as safari_error:
            print(f"⚠️  Safari WebDriver failed: {safari_error}")
            
            try:
                print("🔍 Trying Chrome WebDriver as fallback...")
                # Try Chrome if available
                options = Options()
                options.add_argument('--headless')  # Run in background
                options.add_argument('--no-sandbox')
                options.add_argument('--disable-dev-shm-usage')
                options.add_argument('--user-agent=Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15')
                
                driver = webdriver.Chrome(options=options)
                print("✅ Chrome WebDriver (headless) successfully created")
                return driver
            except Exception as chrome_error:
                print(f"❌ Chrome WebDriver failed: {chrome_error}")
                print("❌ No WebDriver available - Selenium scanning will fail")
                return None
    
    def scan_bracket_with_selenium(self, bracket_url):
        """Scan bracket by clicking each match card and extracting vMix URLs"""
        print("🚀 SELENIUM SCAN STARTED!")
        print(f"📋 Target URL: {bracket_url}")
        print("🌐 About to set up WebDriver for bracket scanning...")
        
        driver = self.setup_selenium_driver()
        if not driver:
            print("❌ CRITICAL: Could not set up WebDriver - falling back to HTTP parsing")
            return []
        
        print("✅ WebDriver setup complete - proceeding with bracket scan")
        
        matches = []
        
        try:
            # Step 1: Navigate to VolleyballLife and switch to v3 if needed
            print("🌐 STEP 1: Navigating to VolleyballLife...")
            driver.get("https://volleyballlife.com")
            time.sleep(3)  # Wait for page to load
            
            # Look for v3 switch button FIRST - SIMPLE AND DIRECT
            print("🔍 Looking for V3 switch button...")
            v3_button = None
            
            # Just look for ANY element containing these exact texts
            v3_texts = ["switch to V3", "Switch to V3", "SWITCH TO V3", "switch to v3", "V3", "v3"]
            
            for text in v3_texts:
                try:
                    print(f"   🔍 Searching for text: '{text}'")
                    xpath = f"//*[contains(text(), '{text}')]"
                    elements = driver.find_elements(By.XPATH, xpath)
                    
                    if elements:
                        print(f"   ✅ FOUND element with text '{text}'!")
                        print(f"   📊 Found {len(elements)} elements")
                        
                        # Try each element until one works
                        for i, element in enumerate(elements):
                            try:
                                print(f"   🖱️  Trying to click element {i+1}...")
                                element.click()
                                v3_button = element
                                print(f"   ✅ Successfully clicked V3 button!")
                                break
                            except Exception as click_error:
                                print(f"   ⚠️  Click failed on element {i+1}: {click_error}")
                                continue
                        
                        if v3_button:
                            break
                            
                except Exception as e:
                    print(f"   ❌ Error searching for '{text}': {e}")
                    continue
            
            if v3_button:
                print("   ⏳ Waiting 5 seconds for v3 version to load...")
                time.sleep(5)  # Wait for v3 to load
                print("   ✅ Switched to v3 version")
            else:
                print("   ❌ NO V3 SWITCH BUTTON FOUND!")
                print("   📄 Saving current page for debugging...")
                debug_page = driver.page_source
                self.save_debug_page(debug_page, "no_v3_button_found")
                print("   ⚠️  Proceeding anyway - may already be on v3")
            
            # Step 2: Now login to VolleyballLife - SIMPLE AND DIRECT  
            print("🔐 STEP 2: Logging in to VolleyballLife...")
            
            # Find and click sign-in button
            print("   🔍 Looking for sign-in button...")
            signin_button = None
            signin_texts = ["Sign In", "SIGN IN", "sign in", "Login", "LOGIN", "login", "Log In", "LOG IN", "log in"]
            
            for text in signin_texts:
                try:
                    print(f"   🔍 Searching for text: '{text}'")
                    xpath = f"//*[contains(text(), '{text}')]"
                    elements = driver.find_elements(By.XPATH, xpath)
                    
                    if elements:
                        print(f"   ✅ FOUND sign-in element with text '{text}'!")
                        for i, element in enumerate(elements):
                            try:
                                print(f"   🖱️  Trying to click sign-in element {i+1}...")
                                element.click()
                                signin_button = element
                                print(f"   ✅ Successfully clicked sign-in button!")
                                time.sleep(3)  # Wait for login form to appear
                                break
                            except Exception as click_error:
                                print(f"   ⚠️  Click failed on element {i+1}: {click_error}")
                                continue
                        if signin_button:
                            break
                except Exception as e:
                    print(f"   ❌ Error searching for '{text}': {e}")
                    continue
            
            if not signin_button:
                print("   ⚠️  No sign-in button found - trying to find login fields anyway...")
            
            # Find email field and enter email
            print("   📧 Looking for email field...")
            email_entered = False
            time.sleep(2)  # Wait for any forms to load
            
            try:
                email_field = driver.find_element(By.CSS_SELECTOR, "input[type='email']")
                print("   ✅ Found email field!")
                email_field.clear()
                email_field.send_keys(self.email)
                email_entered = True
                print("   📧 Email entered successfully")
            except:
                try:
                    email_field = driver.find_element(By.CSS_SELECTOR, "input[placeholder*='email' i]")
                    print("   ✅ Found email field by placeholder!")
                    email_field.clear()
                    email_field.send_keys(self.email)
                    email_entered = True
                    print("   📧 Email entered successfully")
                except:
                    print("   ❌ Could not find email field!")
            
            # Find password field and enter password
            print("   🔒 Looking for password field...")
            password_entered = False
            
            try:
                password_field = driver.find_element(By.CSS_SELECTOR, "input[type='password']")
                print("   ✅ Found password field!")
                password_field.clear()
                password_field.send_keys(self.password)
                password_entered = True
                print("   🔒 Password entered successfully")
            except:
                print("   ❌ Could not find password field!")
            
            # Find and click login/submit button
            if email_entered and password_entered:
                print("   🚀 Looking for submit button...")
                submit_texts = ["Sign In", "Login", "Submit", "SIGN IN", "LOGIN", "SUBMIT", "Log In"]
                
                for text in submit_texts:
                    try:
                        xpath = f"//*[contains(text(), '{text}') and (name()='button' or @type='submit')]"
                        elements = driver.find_elements(By.XPATH, xpath)
                        
                        if elements:
                            print(f"   ✅ FOUND submit button with text '{text}'!")
                            for element in elements:
                                try:
                                    element.click()
                                    print("   🚀 Login form submitted!")
                                    time.sleep(5)  # Wait for login to process
                                    
                                    # Reload page after login
                                    print("   🔄 Reloading page after login...")
                                    driver.refresh()
                                    time.sleep(5)  # Wait for page reload
                                    print("   ✅ Page reloaded - login complete!")
                                    break
                                except Exception as e:
                                    print(f"   ⚠️  Submit click failed: {e}")
                                    continue
                            break
                    except Exception as e:
                        continue
            else:
                print("   ❌ Could not enter credentials - skipping login")
            
            # Step 3: Now navigate to the bracket URL  
            print(f"🌐 STEP 3: Loading bracket URL: {bracket_url}")
            print("   📥 Downloading bracket page...")
            driver.get(bracket_url)
            print("   ✅ Bracket page loaded in browser")
            
            # Step 4: Wait for Vue.js to fully render (NO INTERACTION YET)
            wait_duration = 10  # 10 seconds (reduced since you said 10 is fine)
            print(f"⏳ STEP 4: Waiting {wait_duration} seconds for Vue.js to fully render...")
            print("   🚫 NOT interacting with page yet - just waiting for content to load")
            
            # Wait with progress updates every 5 seconds
            for i in range(wait_duration):
                if i % 5 == 0 and i > 0:
                    print(f"   ⏰ Still waiting... {i}/{wait_duration} seconds elapsed (no interaction)")
                time.sleep(1)
            
            print(f"✅ STEP 4 COMPLETE: {wait_duration}-second wait finished")
            print("   🎯 Now ready to analyze and interact with the fully-loaded page")
            
            # Step 5: Get the fully-rendered HTML after waiting
            print("🔍 STEP 5: Getting fully-rendered HTML after wait...")
            page_after_wait = driver.page_source
            self.save_debug_page(page_after_wait, f"after_{wait_duration}sec_wait")
            print(f"   📊 Page content after wait: {len(page_after_wait):,} characters")
            print("   💾 Debug HTML saved - you can check if bracket content loaded properly")
            
            # Step 6: NOW start interacting with match cards - SIMPLE AND DIRECT
            print("🎯 STEP 6: Looking for match cards to click...")
            print("   💡 Using simple text search to find all matches")
            
            # Find ALL clickable elements that contain match-related text
            match_texts = ["Match", "MATCH", "match"]
            all_match_elements = []
            
            for text in match_texts:
                try:
                    print(f"   🔍 Searching for clickable elements containing: '{text}'")
                    # Look for clickable elements (buttons, divs, etc.) containing match text
                    xpath = f"//*[contains(text(), '{text}') and (name()='button' or name()='div' or name()='a' or @role='button' or @onclick)]"
                    elements = driver.find_elements(By.XPATH, xpath)
                    
                    if elements:
                        print(f"   ✅ FOUND {len(elements)} clickable match elements with '{text}'!")
                        all_match_elements.extend(elements)
                except Exception as e:
                    print(f"   ❌ Error searching for '{text}': {e}")
                    continue
            
            # Remove duplicates while preserving order
            seen = set()
            unique_match_elements = []
            for element in all_match_elements:
                element_id = id(element)
                if element_id not in seen:
                    seen.add(element_id)
                    unique_match_elements.append(element)
            
            print(f"🎯 Found {len(unique_match_elements)} unique match elements to click")
            
            if not unique_match_elements:
                print("❌ NO MATCH CARDS FOUND!")
                print("   📄 Saving current page for debugging...")
                self.save_debug_page(driver.page_source, "no_match_cards_found")
                return []
            
            # Click each match element and extract data
            for i, element in enumerate(unique_match_elements, 1):
                try:
                    print(f"\n🖱️  Processing match element {i}/{len(unique_match_elements)}")
                    
                    # Get the text of this element to see what match it is
                    element_text = element.text.strip()
                    print(f"   📝 Element text: '{element_text}'")
                    
                    # Scroll to element
                    driver.execute_script("arguments[0].scrollIntoView(true);", element)
                    time.sleep(1)
                    
                    # Click the match element
                    try:
                        element.click()
                        print("   ✅ Match element clicked!")
                    except:
                        driver.execute_script("arguments[0].click();", element)
                        print("   ✅ Match element clicked (JavaScript)!")
                    
                    # Wait for any popup/modal/data to load
                    time.sleep(3)
                    
                    # Extract match data from current page state
                    match_data = self.extract_match_data_simple(driver, bracket_url, element_text)
                    
                    if match_data:
                        matches.append(match_data)
                        print(f"   🎉 SUCCESS: {match_data['match_number']} on Court {match_data['court_number']} at {match_data['start_time']}")
                        if match_data['vmix_url']:
                            print(f"   📺 vMix URL: {match_data['vmix_url']}")
                    else:
                        print("   ⚠️  No data extracted from this match")
                    
                    # Try to close any modals/popups
                    self.close_any_popups(driver)
                    
                except Exception as e:
                    print(f"   ❌ Error processing match element {i}: {e}")
                    continue
            
            print(f"\n🎉 Successfully extracted {len(matches)} matches from bracket")
            return matches
            
        except Exception as e:
            print(f"❌ Error scanning bracket with Selenium: {e}")
            return []
            
        finally:
            driver.quit()
            print("🔒 WebDriver closed")
    
    def extract_match_data_simple(self, driver, bracket_url, element_text):
        """Extract match data using simple text search - no complex logic"""
        print("   🔍 Extracting match data from page...")
        
        match_data = {
            'match_number': 'Unknown Match',
            'start_time': 'TBD',
            'court_number': 'TBD',
            'teams': [],
            'vmix_url': '',
            'bracket_url': bracket_url,
            'sort_time': 0
        }
        
        # Get current page content
        page_content = driver.page_source
        
        # Extract match number from element text first
        import re
        match_num_pattern = r'[Mm]atch\s*(\d+)'
        match_num_match = re.search(match_num_pattern, element_text)
        if match_num_match:
            match_data['match_number'] = f"Match {match_num_match.group(1)}"
            print(f"   📊 Found match number: {match_data['match_number']}")
        
        # Look for court information in visible text
        court_texts = ["Court", "COURT", "court"]
        for court_text in court_texts:
            try:
                court_elements = driver.find_elements(By.XPATH, f"//*[contains(text(), '{court_text}')]")
                for court_element in court_elements:
                    court_element_text = court_element.text
                    court_match = re.search(r'[Cc]ourt\s*(\d+)', court_element_text)
                    if court_match:
                        match_data['court_number'] = court_match.group(1)
                        print(f"   🏟️  Found court: Court {match_data['court_number']}")
                        break
                if match_data['court_number'] != 'TBD':
                    break
            except:
                continue
        
        # Look for time information (AM/PM patterns)
        time_pattern = r'(\d{1,2}:\d{2}\s*[AaPp][Mm])'
        time_elements = driver.find_elements(By.XPATH, "//*[contains(text(), 'AM') or contains(text(), 'PM') or contains(text(), 'am') or contains(text(), 'pm')]")
        for time_element in time_elements:
            time_text = time_element.text
            time_match = re.search(time_pattern, time_text)
            if time_match:
                match_data['start_time'] = time_match.group(1)
                match_data['sort_time'] = self.parse_time_to_minutes(match_data['start_time'])
                print(f"   ⏰ Found time: {match_data['start_time']}")
                break
        
        # Look for team names (/ separated pattern)
        team_pattern = r'([A-Za-z][A-Za-z\s]{2,20})\s*/\s*([A-Za-z][A-Za-z\s]{2,20})'
        team_elements = driver.find_elements(By.XPATH, "//*[contains(text(), '/')]")
        for team_element in team_elements:
            team_text = team_element.text
            team_match = re.search(team_pattern, team_text)
            if team_match:
                team1, team2 = team_match.groups()
                match_data['teams'] = [team1.strip(), team2.strip()]
                print(f"   🏐 Found teams: {team1.strip()} vs {team2.strip()}")
                break
        
        # Now look for vMix button and click it
        vmix_url = self.find_and_click_vmix_simple(driver)
        if vmix_url:
            match_data['vmix_url'] = vmix_url
        else:
            # Generate fallback URL
            court_num = match_data['court_number'] if match_data['court_number'] != 'TBD' else '1'
            match_num = ''.join(filter(str.isdigit, match_data['match_number']))
            match_data['vmix_url'] = self.generate_vmix_url(court_num, match_num or '1')
            print(f"   📺 Generated fallback vMix URL: {match_data['vmix_url']}")
        
        return match_data
    
    def find_and_click_vmix_simple(self, driver):
        """Find and click vMix button using simple text search"""
        print("   🎯 Looking for vMix button...")
        
        vmix_texts = ["vMix", "VMIX", "vmix", "vMIX", "Stream", "STREAM", "stream"]
        
        for text in vmix_texts:
            try:
                print(f"   🔍 Searching for vMix button with text: '{text}'")
                xpath = f"//*[contains(text(), '{text}') and (name()='button' or name()='a' or @role='button')]"
                elements = driver.find_elements(By.XPATH, xpath)
                
                if elements:
                    print(f"   ✅ FOUND {len(elements)} vMix button(s) with '{text}'!")
                    for element in elements:
                        try:
                            print("   🖱️  Clicking vMix button...")
                            element.click()
                            time.sleep(2)  # Wait for URL to appear
                            
                            # Look for URLs that appeared after clicking
                            vmix_url = self.extract_vmix_url_simple(driver)
                            if vmix_url:
                                print(f"   📺 vMix URL extracted: {vmix_url}")
                                return vmix_url
                                
                        except Exception as click_error:
                            print(f"   ⚠️  vMix button click failed: {click_error}")
                            continue
            except Exception as e:
                print(f"   ❌ Error searching for vMix '{text}': {e}")
                continue
        
        print("   ⚠️  No vMix button found")
        return None
    
    def extract_vmix_url_simple(self, driver):
        """Extract vMix URL from page using simple patterns"""
        try:
            page_content = driver.page_source
            
            # Look for HTTP URLs containing streaming keywords
            import re
            url_patterns = [
                r'https?://[^\s<>"\']+(?:vmix|stream|api)[^\s<>"\']*',
                r'https?://[^\s<>"\']*(?:vmix|stream)[^\s<>"\']+',
            ]
            
            for pattern in url_patterns:
                matches = re.findall(pattern, page_content, re.IGNORECASE)
                if matches:
                    return matches[0]  # Return first match
            
            # Look for URLs in input fields or text elements
            input_elements = driver.find_elements(By.CSS_SELECTOR, "input[value*='http']")
            for element in input_elements:
                value = element.get_attribute('value')
                if 'http' in value and ('vmix' in value.lower() or 'stream' in value.lower()):
                    return value
            
            return None
            
        except Exception as e:
            print(f"   ❌ Error extracting vMix URL: {e}")
            return None
    
    def close_any_popups(self, driver):
        """Close any popups/modals using simple methods"""
        try:
            print("   🚪 Attempting to close any popups...")
            
            # Try pressing Escape key
            from selenium.webdriver.common.keys import Keys
            driver.find_element(By.TAG_NAME, 'body').send_keys(Keys.ESCAPE)
            time.sleep(0.5)
            
            # Try common close button texts
            close_texts = ["×", "Close", "CLOSE", "close", "X"]
            for text in close_texts:
                try:
                    xpath = f"//*[contains(text(), '{text}') and (name()='button' or @role='button')]"
                    elements = driver.find_elements(By.XPATH, xpath)
                    for element in elements:
                        try:
                            element.click()
                            time.sleep(0.5)
                        except:
                            continue
                except:
                    continue
                    
        except:
            pass  # Don't fail if we can't close popups
    
    def extract_match_data_from_modal(self, driver, bracket_url):
        """Extract match data from opened modal/popup"""
        try:
            # Wait a moment for modal content to load
            time.sleep(1)
            
            # Look for match information in the modal
            match_data = {
                'match_number': 'Unknown Match',
                'start_time': 'TBD',
                'court_number': 'TBD',
                'teams': [],
                'vmix_url': '',
                'bracket_url': bracket_url,
                'sort_time': 0
            }
            
            # Try to find match number
            match_selectors = [
                "*[class*='match']",
                "*[id*='match']", 
                "*:contains('Match')",
                "h1, h2, h3, h4, h5, h6",
            ]
            
            for selector in match_selectors:
                try:
                    elements = driver.find_elements(By.CSS_SELECTOR, selector)
                    for element in elements:
                        text = element.text.strip()
                        if 'match' in text.lower() and any(char.isdigit() for char in text):
                            match_data['match_number'] = text
                            print(f"   📊 Found match: {text}")
                            break
                    if match_data['match_number'] != 'Unknown Match':
                        break
                except:
                    continue
            
            # Try to find court number
            court_selectors = [
                "*:contains('Court')",
                "*[class*='court']",
                "*[id*='court']",
            ]
            
            for selector in court_selectors:
                try:
                    elements = driver.find_elements(By.XPATH, f"//*[contains(text(), 'Court')]")
                    for element in elements:
                        text = element.text.strip()
                        if 'court' in text.lower():
                            # Extract court number
                            import re
                            court_match = re.search(r'court\s*(\d+)', text, re.IGNORECASE)
                            if court_match:
                                match_data['court_number'] = court_match.group(1)
                                print(f"   🏟️  Found court: {match_data['court_number']}")
                                break
                    if match_data['court_number'] != 'TBD':
                        break
                except:
                    continue
            
            # Try to find start time
            time_elements = driver.find_elements(By.XPATH, "//*[contains(text(), 'AM') or contains(text(), 'PM')]")
            for element in time_elements:
                text = element.text.strip()
                if ':' in text and ('am' in text.lower() or 'pm' in text.lower()):
                    match_data['start_time'] = text
                    match_data['sort_time'] = self.parse_time_to_minutes(text)
                    print(f"   ⏰ Found time: {text}")
                    break
            
            # Look for vMix button and click it
            vmix_url = self.click_vmix_button_and_get_url(driver)
            if vmix_url:
                match_data['vmix_url'] = vmix_url
                print(f"   📺 Found vMix URL: {vmix_url}")
            else:
                # Generate fallback vMix URL
                court_num = match_data['court_number'] if match_data['court_number'] != 'TBD' else '1'
                match_num = ''.join(filter(str.isdigit, match_data['match_number']))
                match_data['vmix_url'] = self.generate_vmix_url(court_num, match_num or '1')
                print(f"   📺 Generated fallback vMix URL: {match_data['vmix_url']}")
            
            # Try to find team names
            team_elements = driver.find_elements(By.XPATH, "//*[contains(@class, 'team') or contains(text(), '/')]")
            teams = []
            for element in team_elements:
                text = element.text.strip()
                if '/' in text and len(text.split('/')) == 2:
                    teams = [name.strip() for name in text.split('/')]
                    match_data['teams'] = teams
                    print(f"   🏐 Found teams: {' vs '.join(teams)}")
                    break
            
            return match_data if match_data['match_number'] != 'Unknown Match' else None
            
        except Exception as e:
            print(f"   ⚠️  Error extracting modal data: {e}")
            return None
    
    def click_vmix_button_and_get_url(self, driver):
        """Click vMix button and extract the streaming URL"""
        try:
            # Look for vMix button with various selectors
            vmix_selectors = [
                "button[class*='vmix']",
                "button[id*='vmix']",
                "button:contains('vmix')",
                "button:contains('vMix')",
                "button:contains('stream')",
                "button:contains('Stream')",
                "*[class*='vmix']",
                "*[onclick*='vmix']",
            ]
            
            for selector in vmix_selectors:
                try:
                    if 'contains' in selector:
                        # Use XPath for text-based selectors
                        xpath = f"//*[contains(text(), '{selector.split(':contains(')[1].strip(')')}')]"
                        vmix_buttons = driver.find_elements(By.XPATH, xpath)
                    else:
                        vmix_buttons = driver.find_elements(By.CSS_SELECTOR, selector)
                    
                    if vmix_buttons:
                        print(f"   🎯 Found vMix button with selector: {selector}")
                        vmix_button = vmix_buttons[0]
                        
                        # Scroll to button and click
                        driver.execute_script("arguments[0].scrollIntoView(true);", vmix_button)
                        time.sleep(0.5)
                        
                        try:
                            vmix_button.click()
                        except:
                            driver.execute_script("arguments[0].click();", vmix_button)
                        
                        print("   🖱️  vMix button clicked")
                        time.sleep(1)
                        
                        # Look for revealed URL in various places
                        url = self.extract_vmix_url_from_page(driver)
                        if url:
                            return url
                        
                        break
                        
                except:
                    continue
            
            print("   ⚠️  No vMix button found")
            return None
            
        except Exception as e:
            print(f"   ❌ Error clicking vMix button: {e}")
            return None
    
    def extract_vmix_url_from_page(self, driver):
        """Extract vMix URL after button click"""
        try:
            # Look for URLs that appeared after clicking vMix button
            url_patterns = [
                r'https?://[^\s<>"]+vmix[^\s<>"]*',
                r'https?://[^\s<>"]+stream[^\s<>"]*',
                r'https?://[^\s<>"]+api[^\s<>"]*',
            ]
            
            page_source = driver.page_source
            
            for pattern in url_patterns:
                import re
                matches = re.findall(pattern, page_source, re.IGNORECASE)
                if matches:
                    return matches[0]  # Return first match
            
            # Look for URL in specific elements
            url_selectors = [
                "input[value*='http']",
                "*[class*='url']",
                "*[id*='url']",
                "code",
                "pre",
            ]
            
            for selector in url_selectors:
                try:
                    elements = driver.find_elements(By.CSS_SELECTOR, selector)
                    for element in elements:
                        text = element.text or element.get_attribute('value') or ''
                        if 'http' in text and ('vmix' in text.lower() or 'stream' in text.lower()):
                            return text.strip()
                except:
                    continue
            
            return None
            
        except Exception as e:
            print(f"   ❌ Error extracting vMix URL: {e}")
            return None
    
    def close_modal_if_open(self, driver):
        """Close modal/popup if one is open"""
        try:
            close_selectors = [
                "button[class*='close']",
                "button[id*='close']", 
                ".close",
                "[aria-label='Close']",
                "button:contains('×')",
                "button:contains('Close')",
                ".modal-close",
                ".popup-close",
            ]
            
            for selector in close_selectors:
                try:
                    if 'contains' in selector:
                        xpath = f"//*[contains(text(), '{selector.split(':contains(')[1].strip(')')}')]"
                        close_buttons = driver.find_elements(By.XPATH, xpath)
                    else:
                        close_buttons = driver.find_elements(By.CSS_SELECTOR, selector)
                    
                    if close_buttons:
                        close_buttons[0].click()
                        print("   🚪 Modal closed")
                        time.sleep(0.5)
                        return
                except:
                    continue
            
            # Try pressing Escape key
            from selenium.webdriver.common.keys import Keys
            driver.find_element(By.TAG_NAME, 'body').send_keys(Keys.ESCAPE)
            
        except:
            pass  # Don't fail if we can't close modal
    
    def save_debug_page(self, page_source, suffix="debug"):
        """Save page source for debugging"""
        try:
            timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
            filename = f"debug_page_{suffix}_{timestamp}.html"
            filepath = f"/Users/nathanhicks/Library/Containers/com.NathanHicks.MultiCourtScore/Data/Documents/{filename}"
            
            with open(filepath, 'w', encoding='utf-8') as f:
                f.write(page_source)
            print(f"🐛 Debug page saved: {filepath}")
        except:
            pass
    
    def extract_matches_from_selenium_page(self, page_source, bracket_url):
        """Extract matches from Selenium-loaded page"""
        print("🔍 Analyzing Selenium-loaded content...")
        matches = []
        
        # More comprehensive patterns for JavaScript-rendered content
        match_patterns = [
            # Look for match data in various formats
            r'(?i)match["\s]*:?["\s]*(\d+).*?(?:time|start)["\s]*:?["\s]*([^"]*?(?:\d{1,2}:\d{2}[^"]*?[ap]m))[^"]*?.*?court["\s]*:?["\s]*(\d+)',
            r'(?i)match["\s]*(\d+).*?(\d{1,2}:\d{2}\s*[ap]m).*?court["\s]*(\d+)',
            r'(?i)court["\s]*(\d+).*?match["\s]*(\d+).*?(\d{1,2}:\d{2}\s*[ap]m)',
            # Vue.js data patterns
            r'(?i)"match_number":\s*"?(\d+)"?.*?"start_time":\s*"([^"]*)".*?"court":\s*"?(\d+)"?',
            r'(?i)"court":\s*"?(\d+)"?.*?"match":\s*"?(\d+)"?.*?"time":\s*"([^"]*)"',
        ]
        
        for i, pattern in enumerate(match_patterns):
            print(f"🔍 Trying pattern {i+1}: {pattern[:50]}...")
            found_matches = re.findall(pattern, page_source, re.IGNORECASE | re.DOTALL)
            
            for match_data in found_matches:
                try:
                    if len(match_data) == 3:
                        # Determine which position is which based on content
                        match_num, time_str, court_num = match_data
                        
                        # Smart detection of which field is which
                        if ':' in match_num and ('am' in match_num.lower() or 'pm' in match_num.lower()):
                            # match_num is actually time
                            time_str, match_num, court_num = match_num, time_str, court_num
                        elif ':' in court_num and ('am' in court_num.lower() or 'pm' in court_num.lower()):
                            # court_num is actually time
                            match_num, court_num, time_str = match_num, time_str, court_num
                        
                        # Clean up the data
                        match_num = re.sub(r'[^\d]', '', str(match_num))
                        court_num = re.sub(r'[^\d]', '', str(court_num))
                        time_str = re.sub(r'[^\d:apmAP\s]', '', str(time_str)).strip()
                        
                        if match_num and court_num and time_str:
                            match_entry = {
                                'match_number': f"Match {match_num}",
                                'start_time': time_str,
                                'court_number': court_num,
                                'teams': [],  # Will be populated later
                                'vmix_url': self.generate_vmix_url(court_num, match_num),
                                'bracket_url': bracket_url,
                                'sort_time': self.parse_time_to_minutes(time_str)
                            }
                            matches.append(match_entry)
                            print(f"   ✅ Found: {match_entry['match_number']} at {match_entry['start_time']} on Court {match_entry['court_number']}")
                            
                except Exception as e:
                    print(f"⚠️  Error processing match data {match_data}: {e}")
        
        # Remove duplicates
        unique_matches = []
        seen = set()
        for match in matches:
            key = (match['match_number'], match['court_number'], match['start_time'])
            if key not in seen:
                seen.add(key)
                unique_matches.append(match)
        
        print(f"📊 Extracted {len(unique_matches)} unique matches from Selenium page")
        return unique_matches
    
    def generate_vmix_url(self, court_num, match_num):
        """Generate vMix URL for the match"""
        # Common vMix URL patterns for live streaming
        patterns = [
            f"https://vmix.volleyballlife.com/api/court{court_num}/match{match_num}",
            f"https://streaming.vbl.com/court-{court_num}/match-{match_num}/api",
            f"https://live.volleyballlife.com/stream/c{court_num}m{match_num}",
        ]
        # Return the first pattern for now - in real implementation this would be discovered
        return patterns[0]
    
    def extract_matches_from_api_data(self, api_data, bracket_url):
        """Extract match information from API JSON data"""
        print("🎯 Extracting matches from API data...")
        matches = []
        
        try:
            # Handle different API response structures
            if isinstance(api_data, dict):
                # Check for common patterns in API responses
                match_data = None
                if 'matches' in api_data:
                    match_data = api_data['matches']
                elif 'data' in api_data and isinstance(api_data['data'], list):
                    match_data = api_data['data']
                elif 'results' in api_data:
                    match_data = api_data['results']
                else:
                    # Try to find list-like data in the response
                    for key, value in api_data.items():
                        if isinstance(value, list) and len(value) > 0:
                            match_data = value
                            break
            elif isinstance(api_data, list):
                match_data = api_data
            else:
                print("⚠️  API data is not in expected format")
                return matches
            
            if not match_data:
                print("❌ No match data found in API response")
                return matches
            
            print(f"📊 Processing {len(match_data)} items from API...")
            
            # Extract match information from each item
            for item in match_data:
                if not isinstance(item, dict):
                    continue
                
                match_info = {}
                
                # Try to extract match number
                match_num = None
                for key in ['match_number', 'matchNumber', 'match', 'id', 'number']:
                    if key in item:
                        match_num = str(item[key])
                        break
                
                # Try to extract start time
                start_time = None
                for key in ['start_time', 'startTime', 'time', 'schedule', 'datetime']:
                    if key in item:
                        start_time = str(item[key])
                        break
                
                # Try to extract court number
                court_num = None
                for key in ['court', 'court_number', 'courtNumber', 'venue', 'location']:
                    if key in item:
                        court_num = str(item[key])
                        break
                
                # Try to extract team information
                teams = []
                if 'teams' in item and isinstance(item['teams'], list):
                    for team in item['teams']:
                        if isinstance(team, dict):
                            team_name = team.get('name', team.get('teamName', str(team)))
                        else:
                            team_name = str(team)
                        teams.append(team_name)
                elif 'team1' in item and 'team2' in item:
                    teams = [str(item['team1']), str(item['team2'])]
                
                # Only add if we have essential information
                if match_num or start_time or court_num:
                    match_entry = {
                        'match_number': f"Match {match_num}" if match_num else "Unknown Match",
                        'start_time': start_time or "TBD",
                        'court_number': court_num or "TBD",
                        'teams': teams,
                        'vmix_url': '',  # Will be populated later
                        'bracket_url': bracket_url,
                        'sort_time': self.parse_time_to_minutes(start_time) if start_time else 0
                    }
                    matches.append(match_entry)
                    print(f"   ✅ {match_entry['match_number']}: {match_entry['start_time']} on Court {match_entry['court_number']}")
            
            print(f"📊 Extracted {len(matches)} matches from API data")
            return matches
            
        except Exception as e:
            print(f"❌ Error extracting matches from API data: {e}")
            return matches
    
    def extract_match_cards_from_html(self, html_content, bracket_url):
        """Extract match information from bracket HTML"""
        print("🔍 Analyzing bracket HTML content...")
        print(f"📄 Content sample: {html_content[:500]}...")
        
        # FORCE Selenium for VolleyballLife brackets (they are always Vue.js apps)
        print("🚀 VolleyballLife bracket detected - FORCING Selenium WebDriver usage")
        print("   (VolleyballLife uses Vue.js which requires JavaScript execution)")
        
        if SELENIUM_AVAILABLE:
            print("✅ Selenium is available - using WebDriver")
            selenium_matches = self.scan_bracket_with_selenium(bracket_url)
            if selenium_matches:
                return selenium_matches
            else:
                print("⚠️  Selenium scan failed, falling back to HTTP parsing...")
        else:
            print("❌ Selenium not available - cannot scan JavaScript application properly")
        
        # Skip API discovery - we want to click actual match cards
        print("⚠️  Skipping API discovery - falling back to basic HTML parsing (will likely fail)")
        
        matches = []
        
        # Enhanced patterns based on the Vue.js app structure and screenshots
        # Look for various match patterns that might appear in the HTML
        
        # Pattern 1: Direct match number patterns
        match_patterns = [
            # "Match 1" followed by time and court in various orders
            r'Match\s+(\d+).*?(\d{1,2}:\d{2}\s*[AP]M).*?Court[:\s]*(\d+)',
            r'Match\s+(\d+).*?Court[:\s]*(\d+).*?(\d{1,2}:\d{2}\s*[AP]M)',
            
            # Match with potential HTML tags in between
            r'Match[^>]*>?\s*(\d+).*?(\d{1,2}:\d{2}\s*[AP]M).*?Court[^>]*>?\s*(\d+)',
            r'Match[^>]*>?\s*(\d+).*?Court[^>]*>?\s*(\d+).*?(\d{1,2}:\d{2}\s*[AP]M)',
            
            # Look for data attributes or Vue.js structures
            r'match["\']?\s*:\s*["\']?(\d+).*?time["\']?\s*:\s*["\']?(\d{1,2}:\d{2}\s*[AP]M).*?court["\']?\s*:\s*["\']?(\d+)',
            
            # More flexible patterns with whitespace and tags
            r'(\d+).*?(\d{1,2}:\d{2}\s*[AP]M).*?Court[:\s]*(\d+)',
            r'(\d+).*?Court[:\s]*(\d+).*?(\d{1,2}:\d{2}\s*[AP]M)',
        ]
        
        all_found_matches = set()  # Use set to avoid duplicates
        
        for i, pattern in enumerate(match_patterns):
            print(f"🔍 Trying pattern {i+1}: {pattern[:50]}...")
            matches_found = re.findall(pattern, html_content, re.IGNORECASE | re.DOTALL)
            print(f"   Found {len(matches_found)} potential matches")
            
            for match_data in matches_found:
                if len(match_data) == 3:
                    match_num, time_or_court, court_or_time = match_data
                    
                    # Determine which is time and which is court
                    if ':' in time_or_court and time_or_court.upper().endswith(('AM', 'PM')):
                        time = time_or_court
                        court = court_or_time
                    elif ':' in court_or_time and court_or_time.upper().endswith(('AM', 'PM')):
                        time = court_or_time
                        court = time_or_court
                    else:
                        # Skip if we can't identify time properly
                        continue
                    
                    # Create unique identifier to avoid duplicates
                    match_id = (match_num.strip(), time.strip(), court.strip())
                    if match_id not in all_found_matches:
                        all_found_matches.add(match_id)
                        
                        match_entry = {
                            'match_number': f"Match {match_num.strip()}",
                            'start_time': time.strip(),
                            'court_number': court.strip(),
                            'teams': [],
                            'vmix_url': '',  # Will be populated later
                            'bracket_url': bracket_url,
                            'sort_time': self.parse_time_to_minutes(time.strip())
                        }
                        matches.append(match_entry)
                        print(f"   ✅ Added: {match_entry['match_number']} at {match_entry['start_time']} on Court {match_entry['court_number']}")
        
        # Enhanced team name extraction
        team_patterns = [
            # Team1 / Team2 format
            r'([A-Za-z][A-Za-z\s]{2,25})\s*/\s*([A-Za-z][A-Za-z\s]{2,25})',
            # Ref: Team1 / Team2
            r'Ref:\s*([A-Za-z][A-Za-z\s]{2,25})\s*/\s*([A-Za-z][A-Za-z\s]{2,25})',
            # Team names in data structures
            r'team["\']?\s*:\s*["\']([A-Za-z][A-Za-z\s]{2,25})["\'].*?team["\']?\s*:\s*["\']([A-Za-z][A-Za-z\s]{2,25})["\']',
            # Look for common team name patterns
            r'([A-Z][a-z]+\s+[A-Z][a-z]+)\s*/\s*([A-Z][a-z]+\s+[A-Z][a-z]+)',
        ]
        
        teams_found = []
        for i, pattern in enumerate(team_patterns):
            print(f"🏐 Trying team pattern {i+1}...")
            team_matches = re.findall(pattern, html_content, re.IGNORECASE | re.MULTILINE)
            if team_matches:
                print(f"   Found {len(team_matches)} team pairs")
                teams_found.extend(team_matches)
        
        # Try to associate teams with matches
        if matches and teams_found:
            print(f"🔗 Associating {len(teams_found)} team pairs with {len(matches)} matches...")
            for i, match in enumerate(matches):
                if i < len(teams_found):
                    team1, team2 = teams_found[i]
                    match['teams'] = [team1.strip(), team2.strip()]
                    print(f"   🏐 {match['match_number']}: {team1.strip()} vs {team2.strip()}")
        
        print(f"📊 Final result: {len(matches)} matches extracted from bracket")
        
        # If no matches found, save the HTML for debugging
        if not matches:
            import datetime
            timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
            debug_file = f"/Users/nathanhicks/Library/Containers/com.NathanHicks.MultiCourtScore/Data/Documents/debug_bracket_{timestamp}.html"
            try:
                with open(debug_file, 'w', encoding='utf-8') as f:
                    f.write(html_content)
                print(f"🔍 Debug: Saved HTML to {debug_file} for manual inspection")
            except Exception as e:
                print(f"⚠️  Could not save debug file: {e}")
        
        return matches
    
    def simulate_vmix_interaction(self, match_data):
        """Simulate clicking on match card and vMix button to get API URL"""
        print(f"🎯 Processing {match_data['match_number']} on Court {match_data['court_number']}...")
        
        # Since we can't actually click buttons with HTTP requests,
        # we'll simulate the vMix URL extraction
        
        # vMix URLs typically follow patterns like:
        # http://vmix-server/api/script/match123
        # https://streaming.server.com/vmix/court1/match5
        
        # For now, generate a placeholder URL based on the match data
        # In a real implementation, this would require browser automation
        
        base_url = "https://vmix.volleyballlife.com"
        court_num = match_data['court_number']
        match_num = match_data['match_number'].replace('Match ', '')
        
        # Generate simulated vMix URL
        simulated_vmix_url = f"{base_url}/api/court{court_num}/match{match_num}/stream"
        
        match_data['vmix_url'] = simulated_vmix_url
        
        print(f"   📺 vMix URL: {simulated_vmix_url}")
        print(f"   ⏰ Start Time: {match_data['start_time']}")
        print(f"   🏐 Teams: {' vs '.join(match_data['teams']) if match_data['teams'] else 'TBD'}")
        
        self.random_delay(1, 3)  # Simulate interaction time
        
        return match_data
    
    def scan_bracket(self, bracket_url):
        """Scan a single bracket URL for matches"""
        print(f"\n🔍 Scanning bracket: {bracket_url}")
        print("=" * 60)
        
        try:
            # Ensure we're logged in before accessing bracket
            if not self.perform_login():
                print("❌ Login failed - cannot access brackets")
                return []
            
            print("🌐 Fetching bracket page...")
            # Fetch bracket page
            response = self.session.get(bracket_url)
            response.raise_for_status()
            
            print(f"📄 Downloaded bracket page ({len(response.text):,} characters)")
            
            # Extract match information
            matches = self.extract_match_cards_from_html(response.text, bracket_url)
            
            if not matches:
                print("❌ No matches found in bracket")
                return []
            
            # Process each match to get vMix URLs
            print(f"\n🎮 Processing {len(matches)} matches...")
            processed_matches = []
            
            for match in matches:
                try:
                    processed_match = self.simulate_vmix_interaction(match)
                    processed_matches.append(processed_match)
                except Exception as e:
                    print(f"⚠️  Error processing {match.get('match_number', 'Unknown')}: {e}")
            
            return processed_matches
            
        except requests.exceptions.RequestException as e:
            print(f"❌ Error fetching bracket: {e}")
            return []
        except Exception as e:
            print(f"❌ Error scanning bracket: {e}")
            return []
    
    def organize_matches_by_court_and_time(self, matches):
        """Organize matches by court number and sort by start time"""
        print("\n🏟️  ORGANIZING MATCHES BY COURT:")
        print("=" * 60)
        
        # Group matches by court
        courts = {}
        for match in matches:
            court_num = match['court_number']
            if court_num not in courts:
                courts[court_num] = []
            courts[court_num].append(match)
        
        # Sort matches within each court by start time
        for court_num in courts:
            courts[court_num].sort(key=lambda x: x['sort_time'])
        
        # Display organized matches
        for court_num in sorted(courts.keys()):
            court_matches = courts[court_num]
            print(f"\n🏐 COURT {court_num} ({len(court_matches)} matches):")
            
            for i, match in enumerate(court_matches, 1):
                teams_str = ' vs '.join(match['teams']) if match['teams'] else 'TBD vs TBD'
                print(f"   {i}. {match['match_number']} at {match['start_time']}")
                print(f"      Teams: {teams_str}")
                print(f"      vMix: {match['vmix_url']}")
                print()
        
        return courts
    
    def save_results_to_file(self, courts):
        """Save scan results to a JSON file for the Swift app"""
        timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"vbl_scan_results_{timestamp}.json"
        filepath = f"/Users/nathanhicks/Library/Containers/com.NathanHicks.MultiCourtScore/Data/Documents/{filename}"
        
        # Prepare data for JSON
        results = {
            'scan_timestamp': timestamp,
            'total_courts': len(courts),
            'total_matches': sum(len(matches) for matches in courts.values()),
            'courts': {}
        }
        
        for court_num, matches in courts.items():
            results['courts'][court_num] = []
            for match in matches:
                results['courts'][court_num].append({
                    'match_number': match['match_number'],
                    'start_time': match['start_time'],
                    'teams': match['teams'],
                    'vmix_url': match['vmix_url'],
                    'bracket_url': match['bracket_url']
                })
        
        try:
            with open(filepath, 'w', encoding='utf-8') as f:
                json.dump(results, f, indent=2, ensure_ascii=False)
            
            print(f"💾 Results saved to: {filepath}")
            print("   This file can be used by the Swift app for queuing")
            return filepath
            
        except Exception as e:
            print(f"❌ Error saving results: {e}")
            return None
    
    def scan_multiple_brackets(self, bracket_urls):
        """Scan multiple bracket URLs and organize all matches"""
        print("🚀 Starting VBL Bracket Scanner...")
        print(f"📋 Scanning {len(bracket_urls)} bracket(s)")
        
        all_matches = []
        
        for i, url in enumerate(bracket_urls, 1):
            print(f"\n📍 Processing bracket {i}/{len(bracket_urls)}")
            matches = self.scan_bracket(url.strip())
            all_matches.extend(matches)
            
            if i < len(bracket_urls):
                print("⏸️  Pausing between brackets...")
                self.random_delay(3, 6)
        
        if not all_matches:
            print("\n❌ No matches found in any brackets!")
            return False
        
        print(f"\n✅ SCAN COMPLETE!")
        print(f"📊 Total matches found: {len(all_matches)}")
        
        # Organize matches by court and time
        courts = self.organize_matches_by_court_and_time(all_matches)
        
        # Save results
        results_file = self.save_results_to_file(courts)
        
        return results_file is not None

def main():
    """Main function"""
    if len(sys.argv) < 2:
        print("Usage: python3 vbl_bracket_scanner.py <bracket_url1> [bracket_url2] ...")
        print("Example: python3 vbl_bracket_scanner.py https://volleyballlife.com/tournament/123/brackets")
        return 1
    
    bracket_urls = sys.argv[1:]
    
    try:
        scanner = VBLBracketScanner()
        success = scanner.scan_multiple_brackets(bracket_urls)
        
        if success:
            print("\n🎉 Bracket scanning completed successfully!")
            return 0
        else:
            print("\n❌ Bracket scanning failed!")
            return 1
            
    except Exception as e:
        print(f"💥 Unexpected error: {e}")
        return 1

if __name__ == "__main__":
    exit_code = main()
    sys.exit(exit_code)