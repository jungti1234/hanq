#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage diagnostic-review)
trap 'rm -rf "$stage"' EXIT
mkdir -p .build/hanq/module-cache
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Sources/HanQ/DiagnosticReview.swift Tests/DiagnosticReview/main.swift -o "$stage/tests"
hanq_test_run "$stage/tests"
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Sources/HanQ/DiagnosticReview.swift Tests/DiagnosticReviewIntegration/main.swift -o "$stage/integration-tests"
cp scripts/summarize-input-incident.py "$stage/summarize-input-incident.py"
hanq_test_run "$stage/integration-tests"
if [[ "${1:-}" == --ui ]]; then
    swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Sources/HanQ/DiagnosticReview.swift Sources/HanQ/DiagnosticReviewController.swift Tests/DiagnosticReviewUI/main.swift -o "$stage/ui-tests"
    cp Resources/HanQ-Logo.png "$stage/HanQ-Logo.png"
    hanq_test_run "$stage/ui-tests" "$stage/review.png"
    mkdir -p .build/hanq/diagnostic-review
    cp "$stage/review.png" .build/hanq/diagnostic-review/review.png
    cp "$stage/review-dark-summary.png" "$stage/review-light-environment.png" .build/hanq/diagnostic-review/
fi
