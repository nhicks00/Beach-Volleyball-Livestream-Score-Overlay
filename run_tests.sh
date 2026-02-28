#!/bin/bash
# MultiCourtScore Test Runner
# Usage:
#   ./run_tests.sh              # Run all offline tests (unit + parse)
#   ./run_tests.sh --swift      # Swift unit tests only
#   ./run_tests.sh --python     # Python unit tests only
#   ./run_tests.sh --all        # Everything including integration (needs playwright + internet)
#   ./run_tests.sh --setup      # Set up the Python venv with all dependencies

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRAPERS_DIR="$PROJECT_DIR/MultiCourtScore/Scrapers"
VENV_DIR="$PROJECT_DIR/scraper_venv"
VENV_PYTHON="$VENV_DIR/bin/python3"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

run_swift_tests() {
    echo -e "${BLUE}Running Swift unit tests...${NC}"
    cd "$PROJECT_DIR"
    if xcodebuild test \
        -project MultiCourtScore.xcodeproj \
        -scheme MultiCourtScore \
        -destination 'platform=macOS' \
        -only-testing:MultiCourtScoreTests \
        2>&1 | tee /tmp/swift_test_output.log | grep -E "passed|failed|TEST (SUCCEEDED|FAILED)"; then
        echo -e "${GREEN}Swift tests PASSED${NC}"
        return 0
    else
        echo -e "${RED}Swift tests FAILED${NC}"
        return 1
    fi
}

run_python_unit_tests() {
    echo -e "${BLUE}Running Python unit tests...${NC}"
    cd "$SCRAPERS_DIR"

    # Prefer venv python, fall back to system
    local PYTHON="/usr/bin/python3"
    if [ -f "$VENV_PYTHON" ]; then
        PYTHON="$VENV_PYTHON"
    fi

    if $PYTHON -m pytest tests/test_parse_format.py tests/test_core.py -v 2>&1; then
        echo -e "${GREEN}Python unit tests PASSED${NC}"
        return 0
    else
        echo -e "${RED}Python unit tests FAILED${NC}"
        return 1
    fi
}

run_python_integration_tests() {
    echo -e "${BLUE}Running Python integration tests (requires playwright + internet)...${NC}"
    cd "$SCRAPERS_DIR"

    if [ ! -f "$VENV_PYTHON" ]; then
        echo -e "${YELLOW}No venv found. Run: $0 --setup${NC}"
        return 1
    fi

    if ! $VENV_PYTHON -c "import playwright" 2>/dev/null; then
        echo -e "${YELLOW}Playwright not installed. Run: $0 --setup${NC}"
        return 1
    fi

    if $VENV_PYTHON -m pytest tests/test_integration.py -v --timeout=120 2>&1; then
        echo -e "${GREEN}Integration tests PASSED${NC}"
        return 0
    else
        echo -e "${RED}Integration tests FAILED${NC}"
        return 1
    fi
}

setup_venv() {
    echo -e "${BLUE}Setting up Python virtual environment...${NC}"

    # Find best python3
    local PYTHON=""
    for candidate in /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
        if [ -f "$candidate" ]; then
            PYTHON="$candidate"
            break
        fi
    done

    if [ -z "$PYTHON" ]; then
        echo -e "${RED}No Python 3 found${NC}"
        return 1
    fi

    echo "Using: $PYTHON ($($PYTHON --version))"

    # Create venv
    $PYTHON -m venv "$VENV_DIR"
    echo -e "${GREEN}Venv created at $VENV_DIR${NC}"

    # Install dependencies
    echo "Installing playwright..."
    "$VENV_PYTHON" -m pip install --upgrade pip
    "$VENV_PYTHON" -m pip install playwright pytest pytest-asyncio
    "$VENV_PYTHON" -m playwright install chromium

    echo -e "${GREEN}Setup complete!${NC}"
    echo "Run tests with: $0 --all"
}

build_project() {
    echo -e "${BLUE}Building project...${NC}"
    cd "$PROJECT_DIR"
    if xcodebuild -project MultiCourtScore.xcodeproj -scheme MultiCourtScore -configuration Debug build 2>&1 | tail -5; then
        echo -e "${GREEN}Build SUCCEEDED${NC}"
        return 0
    else
        echo -e "${RED}Build FAILED${NC}"
        return 1
    fi
}

# --- Main ---

case "${1:-}" in
    --swift)
        run_swift_tests
        ;;
    --python)
        run_python_unit_tests
        ;;
    --integration)
        run_python_integration_tests
        ;;
    --all)
        echo -e "${BLUE}=== Full Test Suite ===${NC}\n"
        FAILURES=0

        build_project || ((FAILURES++))
        echo ""
        run_swift_tests || ((FAILURES++))
        echo ""
        run_python_unit_tests || ((FAILURES++))
        echo ""
        run_python_integration_tests || ((FAILURES++))

        echo ""
        if [ $FAILURES -eq 0 ]; then
            echo -e "${GREEN}=== ALL TESTS PASSED ===${NC}"
        else
            echo -e "${RED}=== $FAILURES TEST SUITE(S) FAILED ===${NC}"
            exit 1
        fi
        ;;
    --setup)
        setup_venv
        ;;
    --build)
        build_project
        ;;
    *)
        echo -e "${BLUE}=== Offline Test Suite ===${NC}\n"
        FAILURES=0

        build_project || ((FAILURES++))
        echo ""
        run_swift_tests || ((FAILURES++))
        echo ""
        run_python_unit_tests || ((FAILURES++))

        echo ""
        if [ $FAILURES -eq 0 ]; then
            echo -e "${GREEN}=== ALL OFFLINE TESTS PASSED ===${NC}"
        else
            echo -e "${RED}=== $FAILURES TEST SUITE(S) FAILED ===${NC}"
            exit 1
        fi
        ;;
esac
