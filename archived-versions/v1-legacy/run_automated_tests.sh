#!/bin/bash

# Automated UI Testing and Fixing Script for MultiCourtScore
# This script runs the full test-fix-repeat cycle

set -e

PROJECT_DIR="/Users/nathanhicks/NATHANS APPS/MultiCourtScore"
LOG_DIR="$PROJECT_DIR/TestResults"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Create log directory
mkdir -p "$LOG_DIR"

echo -e "${BLUE}🚀 Starting Automated UI Testing Suite${NC}"
echo "Project: MultiCourtScore"
echo "Timestamp: $TIMESTAMP"
echo "Logs: $LOG_DIR"
echo ""

# Function to log messages
log() {
    echo -e "$1" | tee -a "$LOG_DIR/test_run_$TIMESTAMP.log"
}

# Function to build project
build_project() {
    log "${BLUE}🔨 Building project...${NC}"
    
    cd "$PROJECT_DIR"
    if xcodebuild -project MultiCourtScore.xcodeproj -scheme MultiCourtScore -configuration Debug build > "$LOG_DIR/build_$TIMESTAMP.log" 2>&1; then
        log "${GREEN}✅ Build successful${NC}"
        return 0
    else
        log "${RED}❌ Build failed${NC}"
        log "Build errors:"
        tail -20 "$LOG_DIR/build_$TIMESTAMP.log" | while read line; do
            log "  $line"
        done
        return 1
    fi
}

# Function to run UI tests
run_ui_tests() {
    log "${BLUE}🧪 Running UI tests...${NC}"
    
    cd "$PROJECT_DIR"
    
    # Run the automated UI test suite
    if xcodebuild test \
        -project MultiCourtScore.xcodeproj \
        -scheme MultiCourtScore \
        -destination 'platform=macOS' \
        -only-testing:MultiCourtScoreUITests/AutomatedUITestSuite/testAutomatedUITestingSuite \
        > "$LOG_DIR/uitest_$TIMESTAMP.log" 2>&1; then
        
        log "${GREEN}✅ UI tests completed successfully${NC}"
        return 0
    else
        log "${YELLOW}⚠️  UI tests completed with issues${NC}"
        
        # Extract key information from test logs
        log "Test results summary:"
        grep -E "(PASS|FAIL|crash|hang|timeout)" "$LOG_DIR/uitest_$TIMESTAMP.log" | tail -10 | while read line; do
            log "  $line"
        done
        
        return 1
    fi
}

# Function to run fix-test cycle
run_fix_test_cycle() {
    log "${BLUE}🔄 Running automated fix-test cycle...${NC}"
    
    cd "$PROJECT_DIR"
    
    if xcodebuild test \
        -project MultiCourtScore.xcodeproj \
        -scheme MultiCourtScore \
        -destination 'platform=macOS' \
        -only-testing:MultiCourtScoreUITests/AutomatedFixTestCycle/testAutomatedFixTestCycle \
        > "$LOG_DIR/fixcycle_$TIMESTAMP.log" 2>&1; then
        
        log "${GREEN}✅ Fix-test cycle completed${NC}"
        return 0
    else
        log "${YELLOW}⚠️  Fix-test cycle completed with remaining issues${NC}"
        return 1
    fi
}

# Function to generate summary report
generate_report() {
    log "${BLUE}📊 Generating test summary report...${NC}"
    
    REPORT_FILE="$LOG_DIR/summary_report_$TIMESTAMP.md"
    
    cat > "$REPORT_FILE" << EOF
# MultiCourtScore Automated Test Report

**Date:** $(date)
**Timestamp:** $TIMESTAMP

## Test Summary

### Build Status
$(if [ -f "$LOG_DIR/build_$TIMESTAMP.log" ]; then
    if grep -q "BUILD SUCCEEDED" "$LOG_DIR/build_$TIMESTAMP.log"; then
        echo "✅ **PASSED** - Project built successfully"
    else
        echo "❌ **FAILED** - Build errors detected"
    fi
else
    echo "⚠️ **UNKNOWN** - Build log not found"
fi)

### UI Test Results
$(if [ -f "$LOG_DIR/uitest_$TIMESTAMP.log" ]; then
    echo "#### Smoke Test Results"
    if grep -q "✅ Smoke Test PASSED" "$LOG_DIR/uitest_$TIMESTAMP.log"; then
        echo "✅ **PASSED** - Primary flow working correctly"
    else
        echo "❌ **FAILED** - Issues found in primary flow"
    fi
    
    echo ""
    echo "#### Monkey Test Results"
    if grep -q "✅ Monkey Test completed" "$LOG_DIR/uitest_$TIMESTAMP.log"; then
        ACTIONS=$(grep "Completed.*actions" "$LOG_DIR/uitest_$TIMESTAMP.log" | tail -1)
        echo "✅ **COMPLETED** - $ACTIONS"
    else
        echo "❌ **FAILED** - Monkey test did not complete"
    fi
    
    echo ""
    echo "#### Key Findings"
    grep -E "(Found.*matches|crash|hang|timeout|error)" "$LOG_DIR/uitest_$TIMESTAMP.log" | head -10 | while read line; do
        echo "- $line"
    done
else
    echo "⚠️ UI test log not found"
fi)

### Fix Cycle Results
$(if [ -f "$LOG_DIR/fixcycle_$TIMESTAMP.log" ]; then
    if grep -q "All tests passed" "$LOG_DIR/fixcycle_$TIMESTAMP.log"; then
        echo "🎉 **SUCCESS** - All issues resolved automatically"
    elif grep -q "Same error occurred.*times" "$LOG_DIR/fixcycle_$TIMESTAMP.log"; then
        echo "⚠️ **STOPPED** - Recurring issue detected, manual intervention needed"
    else
        echo "🔄 **IN PROGRESS** - Some issues resolved, others may remain"
    fi
else
    echo "⚠️ Fix cycle log not found"
fi)

## Detailed Logs

- Build Log: \`build_$TIMESTAMP.log\`
- UI Test Log: \`uitest_$TIMESTAMP.log\`
- Fix Cycle Log: \`fixcycle_$TIMESTAMP.log\`

## Screenshots

Test screenshots are automatically captured and saved in the test results directory.

---
*Report generated automatically by MultiCourtScore Automated Testing Suite*
EOF

    log "${GREEN}📝 Report generated: $REPORT_FILE${NC}"
    
    # Also display summary in terminal
    log "\n${BLUE}=== TEST SUMMARY ===${NC}"
    cat "$REPORT_FILE" | grep -E "(✅|❌|⚠️|🎉|🔄)" | while read line; do
        log "$line"
    done
}

# Function to open results
open_results() {
    log "${BLUE}📂 Opening results directory...${NC}"
    open "$LOG_DIR"
}

# Main execution
main() {
    # Step 1: Build the project
    if ! build_project; then
        log "${RED}💥 Build failed, cannot proceed with tests${NC}"
        generate_report
        return 1
    fi
    
    # Step 2: Run UI tests
    log "\n${BLUE}=== RUNNING UI TESTS ===${NC}"
    run_ui_tests
    
    # Step 3: Run automated fix cycle
    log "\n${BLUE}=== RUNNING FIX CYCLE ===${NC}"
    run_fix_test_cycle
    
    # Step 4: Generate report
    log "\n${BLUE}=== GENERATING REPORT ===${NC}"
    generate_report
    
    # Step 5: Open results
    open_results
    
    log "\n${GREEN}🎯 Automated testing completed!${NC}"
    log "Check the report and logs in: $LOG_DIR"
}

# Handle script arguments
case "${1:-}" in
    "build")
        build_project
        ;;
    "test")
        run_ui_tests
        ;;
    "fix")
        run_fix_test_cycle
        ;;
    "report")
        generate_report
        ;;
    *)
        main
        ;;
esac