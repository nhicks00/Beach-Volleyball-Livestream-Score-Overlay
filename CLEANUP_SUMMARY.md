# Codebase Cleanup Summary

## Cleaned Up (2026-01-09)

### Test Files Removed
- ✅ All test JSON files from `MultiCourtScore/Scrapers/`:
  - VERIFICATION.json
  - debug_final.json  
  - debug_results.json
  - final_fix_test.json
  - final_solution.json
  - final_test.json
  - final_test2.json
  - html_debug.json
  - test_results.json
  - verification_test.json

### Legacy Code Archived
Moved to `archived-versions/` directory:

- **v1-legacy/** - Original scraper implementation
- **v2-refactored/** - Intermediate refactored version  
- **MultiCourtScore.v1.backup/** - Backup of version 1
- CourtMappingView.swift (orphaned file)
- CourtSelectionView.swift (orphaned file)

### Build Artifacts Removed
- build.log
- build_final.log
- build_final_v2.log
- build_final_v3.log  
- build_final_v4.log
- build_v2.log
- default.profraw

### Old Python Scrapers Removed
- vbl_api_scraper.py
- vbl_bracket_scanner.py
- vbl_complete_login.py
- vbl_interactive_scraper.py
- vbl_login.py
- vbl_login_playwright.py
- vbl_login_simple.py
- vbl_playwright_scraper.py
- vbl_pool_scraper.py
- vbl_precise_scraper.py
- vbl_session.json

### Test Scripts Removed
- test_dom_extraction.js
- test_dom_extraction_fixed.js
- test_playwright.py
- test_simple_login.py
- test_swift_env.py
- inspect_match_structure.js
- debug_page.html

## Production Files Kept

### Active Scraper
- `MultiCourtScore/Scrapers/vbl_scraper/` - Current production scraper
  - `__init__.py`
  - `cli.py` - Command-line interface
  - `core.py` - Core data models
  - `bracket.py` - Bracket scraping logic
  - `pool.py` - Pool scraping logic
  - `parse_format.py` - Format text parsing
  - `teams.py` - Team data handling

### Configuration
- `MultiCourtScore/Scrapers/config/` - Scraper configuration
- `requirements.txt` - Production Python dependencies
- `vbl_credentials.json.example` - Credential template

### Swift Application
- `MultiCourtScore/` - Main application directory
- `MultiCourtScore.xcodeproj/` - Xcode project

## Result
**Before:** 80+ files in root directory  
**After:** 8 essential files + organized subdirectories

Codebase is now clean, organized, and ready for production!
