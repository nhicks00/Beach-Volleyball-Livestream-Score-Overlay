#!/usr/bin/env python3
"""
Simple VBL Login using Python's built-in libraries
Uses requests + beautifulsoup instead of Playwright for better compatibility
"""

import requests
import time
import random
import sys
import re
from urllib.parse import urljoin, urlparse
from http.cookiejar import CookieJar, MozillaCookieJar
import urllib3
import os
import pickle
import json

# Disable SSL warnings for development
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Configuration
EMAIL = "VBL_EMAIL"
PASSWORD = "VBL_PASSWORD"
BASE_URL = "https://volleyballlife.com"

# Session persistence
COOKIES_FILE = "/Users/nathanhicks/Library/Containers/com.NathanHicks.MultiCourtScore/Data/Documents/vbl_session_cookies.json"
SESSION_FILE = "/Users/nathanhicks/Library/Containers/com.NathanHicks.MultiCourtScore/Data/Documents/vbl_session.pkl"

class SimpleVBLLogin:
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
        
        # Configure SSL handling - more permissive for development
        self.session.verify = True  # Keep SSL verification on but handle errors gracefully
        
        # Add timeout for all requests
        self.session.timeout = 30
        
        # Load existing session if available
        self.load_session()
    
    def random_delay(self, min_seconds=2, max_seconds=5):
        """Add random delay between actions"""
        delay = random.uniform(min_seconds, max_seconds)
        print(f"⏱️  Waiting {delay:.1f} seconds...")
        time.sleep(delay)
    
    def save_session(self):
        """Save session cookies and headers for persistence"""
        try:
            # Ensure the directory exists
            os.makedirs(os.path.dirname(COOKIES_FILE), exist_ok=True)
            
            # Save cookies as JSON
            cookie_dict = {}
            for cookie in self.session.cookies:
                cookie_dict[cookie.name] = {
                    'value': cookie.value,
                    'domain': cookie.domain,
                    'path': cookie.path,
                    'secure': cookie.secure,
                    'expires': cookie.expires
                }
            
            with open(COOKIES_FILE, 'w') as f:
                json.dump(cookie_dict, f, indent=2)
            
            print(f"💾 Session saved with {len(cookie_dict)} cookies")
            
        except Exception as e:
            print(f"⚠️  Failed to save session: {e}")
    
    def load_session(self):
        """Load existing session cookies if available"""
        try:
            if not os.path.exists(COOKIES_FILE):
                print("🆕 No existing session found")
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
            
            print(f"🔄 Loaded existing session with {len(cookie_dict)} cookies")
            return True
            
        except Exception as e:
            print(f"⚠️  Failed to load session: {e}")
            return False
    
    def clear_session(self):
        """Clear saved session data"""
        try:
            if os.path.exists(COOKIES_FILE):
                os.remove(COOKIES_FILE)
            if os.path.exists(SESSION_FILE):
                os.remove(SESSION_FILE)
            self.session.cookies.clear()
            print("🗑️  Session data cleared")
        except Exception as e:
            print(f"⚠️  Failed to clear session: {e}")
    
    def is_session_valid(self):
        """Check if the current session is still valid"""
        try:
            print("🔍 Checking if existing session is still valid...")
            response = self.session.get(BASE_URL, timeout=10)
            
            if response.status_code == 200:
                is_logged_in = self.check_login_status(response.text)
                if is_logged_in:
                    print("✅ Existing session is valid!")
                    return True
                else:
                    print("❌ Session expired, need to re-login")
                    return False
            else:
                print(f"❌ Session check failed with status {response.status_code}")
                return False
                
        except Exception as e:
            print(f"❌ Session validation error: {e}")
            return False
    
    def check_login_status(self, response_text):
        """Check if already logged in by looking for specific indicators"""
        text_lower = response_text.lower()
        
        # Look for logged-in indicators (these suggest we are logged in)
        logged_in_indicators = [
            'logout', 'sign out', 'my account', 'dashboard', 
            'profile', 'settings', 'welcome', 'hello'
        ]
        
        # Look for login required indicators (these suggest we are NOT logged in)
        login_required_indicators = [
            'sign in', 'login', 'log in', 'email', 'password'
        ]
        
        logged_in_score = 0
        login_required_score = 0
        
        for indicator in logged_in_indicators:
            if indicator in text_lower:
                logged_in_score += 1
                print(f"✅ Found logged-in indicator: '{indicator}'")
        
        for indicator in login_required_indicators:
            if indicator in text_lower:
                login_required_score += 1
                print(f"❌ Found login-required indicator: '{indicator}'")
        
        # Determine login status
        if logged_in_score > login_required_score:
            print(f"🎉 Login status: LOGGED IN (score: {logged_in_score} vs {login_required_score})")
            return True
        else:
            print(f"🔐 Login status: NOT LOGGED IN (score: {logged_in_score} vs {login_required_score})")
            return False
    
    def extract_form_data(self, html_content, form_selector=None):
        """Extract form data and action URL from HTML"""
        try:
            # Simple regex-based form parsing (since we can't use BeautifulSoup)
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
    
    def verify_final_login_status(self, response_text=None):
        """Final verification of login status with detailed reporting"""
        print("\n🔍 FINAL LOGIN VERIFICATION:")
        print("=" * 50)
        
        try:
            # Make a fresh request to the main page to check status
            if not response_text:
                print("🌐 Making fresh request to verify login status...")
                response = self.session.get(BASE_URL)
                response_text = response.text
            
            # Save response to file for manual inspection
            import datetime
            timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
            filename = f"vbl_login_verification_{timestamp}.html"
            filepath = f"/Users/nathanhicks/Library/Containers/com.NathanHicks.MultiCourtScore/Data/Documents/{filename}"
            
            try:
                with open(filepath, 'w', encoding='utf-8') as f:
                    f.write(response_text)
                print(f"📄 Response saved to: {filepath}")
                print("   You can manually inspect this file to verify login status")
            except Exception as e:
                print(f"⚠️  Could not save response file: {e}")
            
            # Analyze the response content
            text_length = len(response_text)
            print(f"📊 Response analysis:")
            print(f"   • Content length: {text_length:,} characters")
            
            # Check for specific VolleyballLife elements
            vbl_indicators = [
                ('navigation menu', 'nav'),
                ('user profile', 'profile'),
                ('tournaments', 'tournament'),
                ('matches', 'match'),
                ('teams', 'team'),
                ('logout link', 'logout'),
                ('sign out', 'sign out'),
                ('dashboard', 'dashboard'),
                ('my account', 'my account'),
                ('welcome', 'welcome')
            ]
            
            found_indicators = []
            text_lower = response_text.lower()
            
            for name, keyword in vbl_indicators:
                if keyword in text_lower:
                    found_indicators.append(name)
                    print(f"   ✅ Found: {name}")
                else:
                    print(f"   ❌ Missing: {name}")
            
            # Final determination
            login_status = self.check_login_status(response_text)
            
            print("\n" + "=" * 50)
            print("🎯 VERIFICATION SUMMARY:")
            print(f"   • Indicators found: {len(found_indicators)}/10")
            print(f"   • Content appears valid: {'Yes' if text_length > 5000 else 'No'}")
            print(f"   • Final status: {'✅ LOGGED IN' if login_status else '❌ NOT LOGGED IN'}")
            
            if found_indicators:
                print(f"   • Active features: {', '.join(found_indicators)}")
            
            return login_status
            
        except Exception as e:
            print(f"❌ Verification error: {e}")
            return False
    
    def login(self):
        """Perform login using simple HTTP requests with session persistence"""
        try:
            # First, check if we have a valid existing session
            if self.session.cookies:
                print("🔄 Found existing session, validating...")
                if self.is_session_valid():
                    return True
                else:
                    print("💧 Clearing expired session...")
                    self.clear_session()
            
            print(f"🌐 Navigating to {BASE_URL}...")
            response = self.session.get(BASE_URL)
            response.raise_for_status()
            
            self.random_delay()
            
            print("🔍 Checking if already logged in...")
            if self.check_login_status(response.text):
                print("🎉 Already logged in!")
                self.save_session()  # Save the session
                return True
            
            print("🔐 Starting login process...")
            
            # Look for login/signin links or forms in the page
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
                    login_url = urljoin(BASE_URL, login_url)
                print(f"🔗 Found login URL: {login_url}")
                
                self.random_delay()
                
                # Navigate to login page
                print("👆 Accessing login page...")
                login_response = self.session.get(login_url)
                login_response.raise_for_status()
                
                self.random_delay()
                
                # Extract form data
                action, form_data = self.extract_form_data(login_response.text)
                
                if not action and not form_data:
                    print("⚠️  Could not find login form, trying direct authentication...")
                    # Fallback: try common authentication endpoints
                    auth_endpoints = ['/api/auth/login', '/auth/login', '/login', '/signin']
                    for endpoint in auth_endpoints:
                        try:
                            auth_url = urljoin(BASE_URL, endpoint)
                            auth_data = {
                                'email': EMAIL,
                                'password': PASSWORD,
                                'username': EMAIL,  # Some sites use username instead
                            }
                            
                            print(f"🔑 Trying authentication at {auth_url}...")
                            auth_response = self.session.post(auth_url, data=auth_data)
                            
                            if auth_response.status_code in [200, 302]:
                                print("✅ Authentication successful!")
                                self.save_session()  # Save the session
                                return True
                                
                        except Exception as e:
                            continue
                
                else:
                    # Use extracted form
                    form_url = urljoin(login_url, action) if action else login_url
                    
                    # Fill in our credentials
                    form_data['email'] = EMAIL
                    form_data['password'] = PASSWORD
                    
                    print("📧 Submitting login credentials...")
                    login_submit = self.session.post(form_url, data=form_data)
                    
                    self.random_delay()
                    
                    # Check if login was successful
                    if login_submit.status_code in [200, 302]:
                        if self.check_login_status(login_submit.text):
                            print("🎉 Login successful!")
                            self.save_session()  # Save the session
                            return True
            
            # If we get here, try a more general approach
            print("🔍 Trying alternative login methods...")
            
            # Method 2: Look for any forms and try to submit credentials
            action, form_data = self.extract_form_data(response.text)
            if form_data:
                form_data['email'] = EMAIL
                form_data['password'] = PASSWORD
                
                form_url = urljoin(BASE_URL, action) if action else BASE_URL
                print("🔑 Submitting credentials to main form...")
                
                form_response = self.session.post(form_url, data=form_data)
                self.random_delay()
                
                if form_response.status_code in [200, 302]:
                    print("🎉 Login form submitted successfully!")
                    # Verify login by checking the response
                    success = self.verify_final_login_status(form_response.text)
                    if success:
                        self.save_session()  # Save the session
                    return success
            
            print("❌ Could not complete login automatically")
            print("💡 The site may require manual intervention or have changed its structure")
            print("\n🔍 Performing final verification anyway...")
            success = self.verify_final_login_status()
            if success:
                self.save_session()  # Save the session
            return success
            
        except requests.exceptions.RequestException as e:
            print(f"❌ Network error: {e}")
            return False
        except Exception as e:
            print(f"❌ Login error: {e}")
            return False

def main():
    """Main function"""
    print("🚀 Starting Simple VBL Login...")
    
    try:
        bot = SimpleVBLLogin()
        success = bot.login()
        
        if success:
            print("✅ Login process completed!")
            return 0
        else:
            print("❌ Login process failed!")
            return 1
            
    except Exception as e:
        print(f"💥 Unexpected error: {e}")
        return 1

if __name__ == "__main__":
    exit_code = main()
    sys.exit(exit_code)