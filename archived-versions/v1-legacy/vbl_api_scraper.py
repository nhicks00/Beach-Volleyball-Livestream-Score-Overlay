#!/usr/bin/env python3
"""
VolleyballLife API-Based Scraper
Uses both web scraping and direct API calls for better data extraction
"""

import asyncio
import json
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Dict, List
from urllib.parse import urlparse

from vbl_playwright_scraper import VBLPlaywrightScraper


class VBLAPIScraper(VBLPlaywrightScraper):
    """Extended scraper with API support"""
    
    async def analyze_page_structure(self, url: str) -> Dict:
        """Analyze page structure to understand how to extract data"""
        try:
            print(f"🔍 Analyzing page structure: {url}")
            
            await self.page.goto(url)
            await self.page.wait_for_load_state('networkidle')
            
            analysis = {
                'url': url,
                'title': await self.page.title(),
                'text_content_length': len(await self.page.text_content('body') or ''),
                'api_calls': [],
                'dom_elements': {},
                'potential_data_sources': []
            }
            
            # Monitor network requests for API calls
            print("📡 Monitoring network requests...")
            
            # Get all network requests made by the page
            network_events = []
            
            async def log_request(request):
                if 'api' in request.url or 'json' in request.headers.get('accept', ''):
                    network_events.append({
                        'url': request.url,
                        'method': request.method,
                        'headers': dict(request.headers),
                        'resource_type': request.resource_type
                    })
            
            self.page.on('request', log_request)
            
            # Reload page to capture API calls
            await self.page.reload()
            await self.page.wait_for_load_state('networkidle')
            await asyncio.sleep(2)  # Wait for any delayed API calls
            
            analysis['api_calls'] = network_events
            
            # Analyze DOM structure
            dom_analysis = await self.analyze_dom_structure()
            analysis['dom_elements'] = dom_analysis
            
            # Look for data attributes and JavaScript variables
            js_data = await self.extract_javascript_data()
            analysis['potential_data_sources'] = js_data
            
            print(f"📊 Page analysis complete:")
            print(f"   • Title: {analysis['title']}")
            print(f"   • Content length: {analysis['text_content_length']:,} chars")
            print(f"   • API calls found: {len(analysis['api_calls'])}")
            print(f"   • DOM elements analyzed: {len(analysis['dom_elements'])}")
            
            return analysis
            
        except Exception as e:
            print(f"❌ Error analyzing page: {e}")
            return {'error': str(e)}
    
    async def analyze_dom_structure(self) -> Dict:
        """Analyze DOM structure for match-related elements"""
        selectors_to_check = [
            '.bracket', '.brackets', '[class*="bracket"]',
            '.match', '.matches', '[class*="match"]', 
            '.game', '.games', '[class*="game"]',
            '.team', '.teams', '[class*="team"]',
            '.tournament', '[class*="tournament"]',
            '.round', '[class*="round"]',
            '.pool', '[class*="pool"]',
            'table', 'tbody', 'tr', 'td',
            '[data-match]', '[data-game]', '[data-team]'
        ]
        
        dom_info = {}
        
        for selector in selectors_to_check:
            try:
                elements = await self.page.locator(selector).all()
                if elements:
                    dom_info[selector] = {
                        'count': len(elements),
                        'sample_text': (await elements[0].text_content())[:100] if elements else None
                    }
            except Exception:
                continue
        
        return dom_info
    
    async def extract_javascript_data(self) -> List[Dict]:
        """Extract data from JavaScript variables or embedded JSON"""
        data_sources = []
        
        try:
            # Look for common JavaScript data patterns
            page_content = await self.page.content()
            
            # Look for JSON data in script tags
            json_patterns = [
                r'window\.(?:matches|games|brackets?|tournaments?)\s*=\s*(\[.*?\]);',
                r'var\s+(?:matches|games|brackets?|tournaments?)\s*=\s*(\[.*?\]);',
                r'(?:matches|games|brackets?|tournaments?):\s*(\[.*?\])',
            ]
            
            for pattern in json_patterns:
                matches = re.finditer(pattern, page_content, re.DOTALL | re.IGNORECASE)
                for match in matches:
                    try:
                        json_str = match.group(1)
                        data = json.loads(json_str)
                        data_sources.append({
                            'type': 'javascript_json',
                            'pattern': pattern,
                            'data_length': len(data) if isinstance(data, list) else 1,
                            'sample': data[:2] if isinstance(data, list) else str(data)[:200]
                        })
                    except:
                        continue
            
            # Look for API endpoints mentioned in JavaScript
            api_patterns = [
                r'["\']([^"\']*/?api[^"\']*)["\']',
                r'["\']([^"\']*matches[^"\']*)["\']',
                r'["\']([^"\']*brackets?[^"\']*)["\']'
            ]
            
            for pattern in api_patterns:
                matches = re.finditer(pattern, page_content)
                for match in matches:
                    url = match.group(1)
                    if 'api' in url.lower() or 'match' in url.lower():
                        data_sources.append({
                            'type': 'potential_api_endpoint',
                            'url': url
                        })
        
        except Exception as e:
            print(f"⚠️ Error extracting JavaScript data: {e}")
        
        return data_sources
    
    async def try_api_endpoints(self, base_url: str) -> List[Dict]:
        """Try to fetch data from potential API endpoints"""
        results = []
        
        # Parse the URL to extract event/division/round IDs
        url_parts = urlparse(base_url)
        path_parts = url_parts.path.strip('/').split('/')
        
        # Extract IDs from URL pattern like /event/123/division/456/round/789
        event_id = None
        division_id = None
        round_id = None
        
        try:
            for i, part in enumerate(path_parts):
                if part == 'event' and i + 1 < len(path_parts):
                    event_id = path_parts[i + 1]
                elif part == 'division' and i + 1 < len(path_parts):
                    division_id = path_parts[i + 1]
                elif part == 'round' and i + 1 < len(path_parts):
                    round_id = path_parts[i + 1]
        except:
            pass
        
        print(f"🔍 Extracted IDs - Event: {event_id}, Division: {division_id}, Round: {round_id}")
        
        # Common VBL API endpoint patterns
        if event_id and division_id and round_id:
            api_endpoints = [
                f"https://volleyballlife.com/api/events/{event_id}/divisions/{division_id}/rounds/{round_id}/matches",
                f"https://volleyballlife.com/api/events/{event_id}/divisions/{division_id}/matches", 
                f"https://volleyballlife.com/api/events/{event_id}/matches",
                f"https://volleyballlife.com/api/rounds/{round_id}/matches",
                f"https://volleyballlife.com/api/divisions/{division_id}/matches"
            ]
        elif event_id:
            api_endpoints = [
                f"https://volleyballlife.com/api/events/{event_id}/matches"
            ]
        else:
            api_endpoints = []
        
        # Try each API endpoint
        for endpoint in api_endpoints:
            try:
                print(f"🌐 Trying API endpoint: {endpoint}")
                data = await self.get_api_data(endpoint)
                
                if data:
                    results.append({
                        'endpoint': endpoint,
                        'status': 'success',
                        'data_type': type(data).__name__,
                        'data_length': len(data) if isinstance(data, (list, dict)) else 0,
                        'data': data
                    })
                    print(f"✅ API endpoint successful: {endpoint}")
                else:
                    results.append({
                        'endpoint': endpoint,
                        'status': 'no_data'
                    })
            except Exception as e:
                results.append({
                    'endpoint': endpoint,
                    'status': 'error',
                    'error': str(e)
                })
        
        return results
    
    async def comprehensive_scan(self, bracket_url: str) -> Dict:
        """Perform comprehensive scan using multiple methods"""
        print(f"🚀 Starting comprehensive scan of: {bracket_url}")
        
        result = {
            'url': bracket_url,
            'timestamp': datetime.now().isoformat(),
            'methods': {}
        }
        
        try:
            # Method 1: Page structure analysis
            print("\n📋 Method 1: Page Structure Analysis")
            page_analysis = await self.analyze_page_structure(bracket_url)
            result['methods']['page_analysis'] = page_analysis
            
            # Method 2: API endpoint attempts  
            print("\n🌐 Method 2: API Endpoint Discovery")
            api_results = await self.try_api_endpoints(bracket_url)
            result['methods']['api_attempts'] = api_results
            
            # Method 3: Traditional DOM scraping
            print("\n🔍 Method 3: DOM-based Extraction")
            dom_matches = await self.extract_matches()
            result['methods']['dom_scraping'] = {
                'matches_found': len(dom_matches),
                'matches': dom_matches
            }
            
            # Summarize results
            total_matches = 0
            successful_methods = []
            
            # Count matches from API results
            for api_result in api_results:
                if api_result['status'] == 'success' and 'data' in api_result:
                    data = api_result['data']
                    if isinstance(data, list):
                        total_matches += len(data)
                        successful_methods.append('api')
                        break
            
            # Count matches from DOM scraping
            if dom_matches:
                total_matches += len(dom_matches)
                successful_methods.append('dom')
            
            result['summary'] = {
                'total_matches_found': total_matches,
                'successful_methods': successful_methods,
                'status': 'success' if total_matches > 0 else 'no_matches'
            }
            
            print(f"\n✅ Comprehensive scan complete!")
            print(f"   • Total matches found: {total_matches}")
            print(f"   • Successful methods: {', '.join(successful_methods) if successful_methods else 'None'}")
            
        except Exception as e:
            result['error'] = str(e)
            result['status'] = 'error'
            print(f"❌ Error in comprehensive scan: {e}")
        
        return result


async def main():
    """Main execution function"""
    if len(sys.argv) < 2:
        print("Usage: python3 vbl_api_scraper.py <bracket_url>")
        print("Example: python3 vbl_api_scraper.py 'https://volleyballlife.com/event/123/brackets'")
        sys.exit(1)
    
    bracket_url = sys.argv[1]
    
    print(f"🎯 VolleyballLife API Scraper")
    print(f"Target URL: {bracket_url}")
    
    async with VBLAPIScraper(headless=True, timeout=10000) as scraper:
        # Perform comprehensive scan
        result = await scraper.comprehensive_scan(bracket_url)
        
        # Save results
        output_file = Path("comprehensive_scan_results.json")
        with open(output_file, 'w') as f:
            json.dump(result, f, indent=2)
        print(f"\n💾 Complete results saved to {output_file}")
        
        # Print summary
        if 'summary' in result:
            summary = result['summary']
            if summary['status'] == 'success':
                print(f"🎉 Scan successful - found {summary['total_matches_found']} matches!")
            else:
                print(f"⚠️ No matches found, but analysis complete")
        else:
            print(f"💥 Scan failed")


if __name__ == "__main__":
    asyncio.run(main())