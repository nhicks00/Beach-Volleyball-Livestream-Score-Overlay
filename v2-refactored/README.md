# MultiCourtScore v2

A complete refactoring of the beach volleyball live streaming score overlay system.

## Overview

MultiCourtScore is a macOS application that:
1. **Scrapes** VolleyballLife bracket/pool pages to extract match data and live scoring API URLs
2. **Polls** those APIs in real-time for score updates
3. **Serves** score data to OBS browser sources for live stream overlays

## What's New in v2

### Architecture Improvements
- **Modular SwiftUI**: Split 1200+ line `ContentView.swift` into 15+ focused components
- **Consolidated Python Scrapers**: Reduced 6 overlapping scrapers to 2 focused modules
- **Proper State Management**: Clean `@MainActor` isolated view model with dependency injection
- **Secure Credentials**: Credentials stored in app support directory, not in code

### UI/UX Enhancements
- **Modern Design System**: Dark mode optimized with consistent theming
- **Status Indicators**: Animated status badges for live courts
- **Improved Workflows**: Better scanner and assignment interfaces
- **Settings Screen**: Proper preferences with tabs

### Performance & Reliability
- **Score Caching**: Prevent duplicate API requests
- **Staggered Polling**: Avoid thundering herd with jittered intervals
- **Retry Logic**: Graceful handling of network failures
- **Session Persistence**: Reuse browser sessions between scans

## Project Structure

```
v2-refactored/
├── MultiCourtScore/          # Swift macOS app
│   ├── App/                  # App entry point
│   ├── Views/                # SwiftUI views
│   │   ├── Dashboard/        # Main dashboard, court cards
│   │   ├── Scanner/          # VBL scanning interface
│   │   ├── Assignment/       # Match assignment UI
│   │   ├── Settings/         # Preferences
│   │   └── Components/       # Reusable UI components
│   ├── ViewModels/           # Business logic
│   ├── Models/               # Data structures
│   ├── Services/             # Networking, storage
│   └── Utilities/            # Design system, extensions
│
├── Scrapers/                 # Python scraping module
│   └── vbl_scraper/          # Consolidated scraper package
│       ├── core.py           # Base class & data models
│       ├── bracket.py        # Bracket scanning
│       ├── pool.py           # Pool play scanning
│       └── cli.py            # Command-line interface
```

## Getting Started

### Prerequisites
- macOS 13.0+
- Xcode 15.0+
- Python 3.11+
- Playwright (for browser automation)

### Setup

1. **Python Environment**
   ```bash
   cd v2-refactored/Scrapers
   python3 -m venv venv
   source venv/bin/activate
   pip install -r requirements.txt
   playwright install chromium
   ```

2. **Configure Credentials**
   - Open the app and go to Settings > Credentials
   - Enter your VolleyballLife login details
   - These are stored securely in `~/Library/Application Support/MultiCourtScore/`

3. **Build the App**
   - Open `MultiCourtScore.xcodeproj` in Xcode
   - Select the v2 target (when available)
   - Build and run (⌘R)

## Usage

### Basic Workflow

1. **Scan Brackets**
   - Click "Scan VBL" in the top control bar
   - Enter bracket and/or pool URLs
   - Click "Scan" to extract match data

2. **Assign Matches**
   - Click "Assign" to open the assignment tool
   - Use "Auto Assign" or manually assign matches to overlays
   - Click "Import to Courts" to populate queues

3. **Start Streaming**
   - Click "Start All" or start individual courts
   - Copy overlay URLs to OBS browser sources
   - Scores update automatically during polling

### OBS Setup

Each court has an overlay URL in the format:
```
http://localhost:8787/overlay/court/N/
```

Add as a browser source in OBS with:
- Width: 400
- Height: 150
- Custom CSS: `body { background-color: transparent; }`

## Development

### Key Files

| File | Purpose |
|------|---------|
| `AppViewModel.swift` | Main state management |
| `CourtCard.swift` | Individual court display |
| `WebSocketHub.swift` | Local overlay server |
| `Constants.swift` | Design system tokens |
| `core.py` | Scraper base class |
| `bracket.py` | Bracket extraction logic |

### Adding New Features

1. Views go in `Views/` under appropriate subdirectory
2. Business logic in `ViewModels/`
3. Network/storage in `Services/`
4. Update `Constants.swift` for new design tokens

## Migration from v1

The v1 codebase is preserved in `v1-legacy/` for reference. Key changes:

| v1 File | v2 Replacement |
|---------|----------------|
| `ContentView.swift` (1192 lines) | Split into 10+ modular views |
| `vbl_bracket_scanner.py` | `bracket.py` |
| `vbl_pool_scraper.py` | `pool.py` |
| `vbl_complete_login.py` | Integrated into `core.py` |
| Hardcoded credentials | `ConfigStore.swift` |

## License

© 2025 Nathan Hicks. All rights reserved.
