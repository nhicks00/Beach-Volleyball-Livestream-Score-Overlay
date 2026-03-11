#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$PROJECT_DIR"

xcodebuild test \
  -project MultiCourtScore.xcodeproj \
  -scheme MultiCourtScore \
  -destination 'platform=macOS' \
  -only-testing:MultiCourtScoreTests/QueuePollingEdgeCaseTests \
  -only-testing:MultiCourtScoreTests/QueueConclusionTimingTests \
  -only-testing:MultiCourtScoreTests/PollingFailureModeTests \
  -only-testing:MultiCourtScoreTests/SignalRMutationQueueTests \
  -only-testing:MultiCourtScoreTests/SignalRSubscriptionTests \
  -only-testing:MultiCourtScoreTests/OverlayServerLifecycleTests \
  -only-testing:MultiCourtScoreTests/RuntimeLogStoreTests
