# MultiCourtScore V1 Legacy

This folder contains the original v1 codebase for MultiCourtScore, preserved for reference.

## Contents

### Swift macOS App
- `MultiCourtScore/` - Main app source code
- `MultiCourtScoreTests/` - Unit tests
- `MultiCourtScoreUITests/` - UI tests

### Python Scrapers
Multiple scraper implementations that were developed iteratively:

| File | Purpose | Lines |
|------|---------|-------|
| `vbl_bracket_scanner.py` | Selenium-based bracket scanning | 1653 |
| `vbl_playwright_scraper.py` | Playwright base class | 458 |
| `vbl_precise_scraper.py` | Three-phase bracket scan | 844 |
| `vbl_complete_login.py` | Four-phase login workflow | 476 |
| `vbl_pool_scraper.py` | Pool play match extraction | 516 |
| `vbl_login.py` | Login utilities | ~500 |
| `vbl_api_scraper.py` | Direct API access attempts | ~400 |
| `vbl_interactive_scraper.py` | Interactive debugging | ~600 |

### Supporting Files
- `requirements.txt` - Python dependencies
- `*.js` - DOM inspection utilities
- `*.json` - Test results and session data
- `debug_page.html` - Debug page captures

## Notes

This code is preserved for reference. All new development should occur in `v2-refactored/`.

Key issues addressed in v2:
1. Consolidated 6+ scrapers into unified module
2. Removed hardcoded credentials
3. Split 1200-line ContentView.swift into modular components
4. Added proper error handling and logging
5. Improved UI/UX with modern design system
